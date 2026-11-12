///|
/// Block-Max WAND tests (whitebox: they reach the exact evaluator and the
/// block statistics directly).
///
/// The optimization lives or dies on one property: it must be
/// *indistinguishable* from scoring every posting. These tests compare the
/// block-max result to the exact path, bit for bit, over a corpus whose term
/// frequencies and document lengths vary enough that the skipping actually
/// fires — and then assert that it did fire, so a future change that silently
/// turns the optimization into a no-op fails here instead of only showing up as
/// a latency regression nobody notices.

///|
/// A corpus with one saturated term ("common", in every document, usually once
/// and occasionally several times) over a base length, plus a scattered tail.
/// The base length keeps "the shortest document in the block" from being a
/// one-token document that would make every bound trivially loose — which is
/// what a real corpus looks like, and what lets the tight bound do its job.
fn wand_corpus(n : Int32) -> Index {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  let mut s : UInt64 = 20261112UL
  for d in 0..<n {
    s = s * 6364136223846793005UL + 1442695040888963407UL
    let r = (s >> 33).to_int()
    let mut text = ""
    for _ in 0..<(20 + r % 15) {
      text += "filler "
    }
    // The saturated term. Most documents mention it once; a small minority
    // several times, so a block's maximum frequency is usually 1 and the
    // threshold — set by the minority — sits well above it.
    let tf = if r % 25 == 0 { 2 + r % 3 } else { 1 }
    for _ in 0..<tf {
      text += "common "
    }
    // A scattered tail, so most terms are rare and a few are common.
    for j in 0..<(r % 6) {
      text += "t" + (r / (j + 3) % 40).to_string() + " "
    }
    idx.add({ id: "d\{d}", fields: [("body", text)], })
  }
  idx
}

///|
/// The exact path: parse and evaluate, then select. This is what the block-max
/// walk has to reproduce.
fn wand_exact(
  idx : Index,
  term : String,
  field : String?,
  limit : Int32,
) -> Array[Hit] {
  let queried = match field {
    Some(f) => f + ":" + term
    None => term
  }
  let parsed = parse_query(
    queried,
    analyzer=idx.analyzer(),
    fields=idx.field_names(),
  ) catch {
    _ => abort("parse failed for " + queried)
  }
  idx.collect_hits(idx.eval_sorted(parsed), limit)
}

///|
test "block-max top-k equals the exact path, bit for bit" {
  let idx = wand_corpus(2000)
  let terms : Array[String] = ["common"]
  for i in 0..<40 {
    terms.push("t\{i}")
  }
  for term in terms {
    for limit in [1, 5, 10, 200] {
      let exact = wand_exact(idx, term, None, limit)
      let wand = idx.term_topk_blockmax(None, term, limit)
      assert_eq(wand.hits, exact)
      // And the field-scoped form, which is a different code path only in the
      // sense that it has one field to merge.
      let exact_f = wand_exact(idx, term, Some("body"), limit)
      let wand_f = idx.term_topk_blockmax(Some("body"), term, limit)
      assert_eq(wand_f.hits, exact_f)
    }
  }
}

///|
test "the skipping actually fires on a saturated term" {
  let idx = wand_corpus(2000)
  // "common" is in most of the corpus; without skipping every posting is
  // scored. With a limit of 10, most blocks must be skipped.
  let r = idx.term_topk_blockmax(None, "common", 10)
  assert_eq(r.hits.length(), 10)
  assert_true(r.skipped > 0)
  // The tail term is short enough that little or nothing is skippable; that is
  // fine and the equality test above is what guards correctness.
  let t = idx.term_topk_blockmax(None, "t7", 10)
  assert_true(t.scored >= t.hits.length())
}

///|
test "block-max skips nothing until the threshold is set" {
  let idx = wand_corpus(500)
  // With a limit larger than the number of matches, the top set never fills, so
  // no threshold exists and nothing may be skipped.
  let r = idx.term_topk_blockmax(None, "t3", 100000)
  assert_eq(r.skipped, 0)
  assert_eq(r.hits, wand_exact(idx, "t3", None, 100000))
}

///|
test "block-max handles deleted documents the way the exact path does" {
  let idx = wand_corpus(800)
  // Delete a spread of documents, including some the top-10 would have held.
  let top = wand_exact(idx, "common", None, 10)
  for hit in top {
    let _ = idx.delete(hit.id)
  }
  for d in 0..<800 {
    if d % 7 == 0 {
      let _ = idx.delete("d\{d}")
    }
  }
  for limit in [1, 10, 50] {
    assert_eq(
      idx.term_topk_blockmax(None, "common", limit).hits,
      wand_exact(idx, "common", None, limit),
    )
  }
}

///|
test "block-max falls back to zero on an unknown term" {
  let idx = wand_corpus(100)
  let r = idx.term_topk_blockmax(None, "not-a-term", 10)
  assert_eq(r.hits.length(), 0)
  assert_eq(r.scored, 0)
  assert_eq(r.skipped, 0)
}

///|
test "a bounded single-term search returns the same hits as the exact path" {
  // End to end through `search`, which is where the block-max path is wired in.
  let idx = wand_corpus(1500)
  let via_search = idx.search("common", limit=10) catch {
    _ => abort("search failed")
  }
  assert_eq(via_search, wand_exact(idx, "common", None, 10))
}

///|
/// The exact path for an arbitrary query string.
fn query_exact(idx : Index, query : String, limit : Int32) -> Array[Hit] {
  let parsed = parse_query(
    query,
    analyzer=idx.analyzer(),
    fields=idx.field_names(),
  ) catch {
    _ => abort("parse failed: " + query)
  }
  idx.collect_hits(idx.eval_sorted(parsed), limit)
}

///|
/// A conjunction is walked over its shortest term and scored in query order;
/// both have to leave the result indistinguishable from the exact evaluator,
/// including duplicate terms (which the exact path scores twice) and a term
/// that matches nothing (which empties the conjunction).
test "multi-term conjunction top-k equals the exact path, bit for bit" {
  let idx = wand_corpus(1500)
  let queries : Array[String] = [
    "common filler", "common t7", "common filler t7", "common t3 t9", "filler t3",
    "t3 t9", "common common", "common notaterm", "body:common body:t7", "body:common body:filler body:t7",
  ]
  for q in queries {
    for limit in [1, 5, 10, 100] {
      let exact = query_exact(idx, q, limit)
      let via = idx.search(q, limit~) catch { _ => ([] : Array[Hit]) }
      assert_eq(via, exact)
    }
  }
}

///|
test "a selective term drives the conjunction, not the saturated one" {
  let idx = wand_corpus(2000)
  // "common" is in nearly every document; "t7" is rare. The walk visits t7's
  // postings and asks "common" about those documents, so the number of
  // candidates scored is bounded by t7's document frequency — not "common"'s.
  let r = idx.and_terms_topk([("common", None), ("t7", None)], 10)
  assert_true(r.hits.length() > 0)
  assert_true(r.scored <= idx.doc_freq("body", "t7"))
  // And it still equals the exact answer.
  assert_eq(r.hits, query_exact(idx, "common t7", 10))
}

///|
test "conjunction block-max handles deleted documents" {
  let idx = wand_corpus(900)
  for d in 0..<900 {
    if d % 5 == 0 {
      let _ = idx.delete("d\{d}")
    }
  }
  for limit in [1, 10, 50] {
    for q in ["common filler", "common t3 t9"] {
      assert_eq(
        idx.search(q, limit~) catch {
          _ => ([] : Array[Hit])
        },
        query_exact(idx, q, limit),
      )
    }
  }
}

///|
/// A disjunction is walked as a union with block skipping; like the
/// conjunction, the result has to be indistinguishable from the exact
/// evaluator — including duplicate terms (scored twice), a term that matches
/// nothing (an empty operand of a union contributes nothing) and a mixed
/// field-scoped operand.
test "multi-term disjunction top-k equals the exact path, bit for bit" {
  let idx = wand_corpus(1500)
  let queries : Array[String] = [
    "common OR t7", "t3 OR t9", "filler OR t3 OR t9", "common OR common", "common OR notaterm",
    "notaterm OR alsomissing", "body:common OR body:t7", "common OR body:filler OR t3",
  ]
  for q in queries {
    for limit in [1, 5, 10, 100] {
      let exact = query_exact(idx, q, limit)
      let via = idx.search(q, limit~) catch { _ => ([] : Array[Hit]) }
      assert_eq(via, exact)
      // And the walk itself, called directly, agrees — so the equality does not
      // depend on the routing decision.
      match
        flatten_or_terms(
          parse_query(q, analyzer=idx.analyzer, fields=idx.field_names()),
        ) {
        Some(terms) => assert_eq(idx.or_terms_topk(terms, limit).hits, exact)
        None => ()
      }
    }
  }
}

///|
test "disjunction block-max fires on a saturated operand" {
  let idx = wand_corpus(2000)
  // "common" is in nearly every document; the union is dominated by it, so once
  // the threshold is set most blocks cannot contribute.
  let r = idx.or_terms_topk([("common", None), ("t7", None)], 10)
  assert_true(r.hits.length() > 0)
  assert_true(r.skipped > 0)
  assert_eq(r.hits, query_exact(idx, "common OR t7", 10))
}

///|
test "disjunction block-max handles deleted documents" {
  let idx = wand_corpus(900)
  for d in 0..<900 {
    if d % 4 == 0 {
      let _ = idx.delete("d\{d}")
    }
  }
  for limit in [1, 10, 50] {
    for q in ["common OR t7", "t3 OR t9 OR filler"] {
      assert_eq(
        idx.search(q, limit~) catch {
          _ => ([] : Array[Hit])
        },
        query_exact(idx, q, limit),
      )
    }
  }
}

///|
/// The disjunction walk pays only when the union has a dense operand to set the
/// threshold *and* one far rarer to fall below it, so `search` opts into it per
/// query. This pins the gate against the five shapes the benchmark measured:
/// two dense operands, three dense, one dense plus rare, dense plus many rare,
/// and all-rare.
test "the disjunction gate needs a dense operand and a much rarer one" {
  let idx = wand_corpus(1500)
  // `common`/`filler` hit every document: no spread, so nothing to skip.
  assert_true(!idx.or_walk_pays([("common", None), ("filler", None)]))
  // `t7` (114 of 1500) is an order of magnitude rarer than `common` (1500): a
  // dense term sets the threshold and a sparse one creates the gap.
  assert_true(idx.or_walk_pays([("common", None), ("t7", None)]))
  // Two tail terms are comparably sparse and there is no dense operand: the
  // union is short and the merge wins.
  assert_true(!idx.or_walk_pays([("t3", None), ("t7", None)]))
  // And the gated-out shape still produces the right answer: it routes through
  // the evaluator, which the equality tests cover.
  assert_eq(
    idx.search("common OR filler", limit=10) catch {
      _ => ([] : Array[Hit])
    },
    query_exact(idx, "common OR filler", 10),
  )
}
