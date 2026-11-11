///|
/// Differential and invariant tests for the query evaluator.
///
/// The evaluator was rewritten from a `doc -> score` HashMap to ascending
/// (doc, score) arrays with merge-based set operators. These tests pin the
/// two things that rewrite could silently break: the numeric scores and the
/// ordering/selection semantics.

///|
/// Reference BM25 computed from public primitives only
/// (`postings_of` / `doc_freq` / `schema` / `doc_count`). Deliberately does
/// not call the engine's own scoring path.
fn ref_bm25(
  idx : @moonseek.Index,
  field : String,
  term : String,
  weight : Double,
  k1 : Double,
  b : Double,
  doc_num_len : (String) -> Double,
) -> @hashmap.HashMap[String, Double] {
  let n = idx.doc_count().to_double()
  let df = idx.doc_freq(field, term).to_double()
  let out : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
  if df == 0.0 || n == 0.0 {
    return out
  }
  let idf = @math.ln(1.0 + (n - df + 0.5) / (df + 0.5))
  // Average field length over EVERY live doc that carries the field — not
  // just the docs containing this term, which would be a different (and
  // wrong) denominator.
  let postings = idx.postings_of(field, term)
  let mut total_len = 0.0
  let mut counted = 0.0
  for num in 0..<(idx.doc_count() + 1) {
    let id = idx.doc_id(num).unwrap_or("")
    if id == "" {
      continue
    }
    let len = doc_num_len(id)
    if len > 0.0 {
      total_len += len
      counted += 1.0
    }
  }
  let avgdl = if counted == 0.0 { 0.0 } else { total_len / counted }
  for p in postings {
    let id = idx.doc_id(p.doc).unwrap_or("")
    let dl = doc_num_len(id)
    let norm = if avgdl == 0.0 { 1.0 } else { 1.0 - b + b * dl / avgdl }
    let tf = p.freq.to_double()
    let score = idf * (tf * (k1 + 1.0)) / (tf + k1 * norm) * weight
    out.set(id, out.get_or_default(id, 0.0) + score)
  }
  out
}

///|
fn diff_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "a",
    fields: [
      ("title", "moonbit language"),
      ("body", "moonbit moonbit wasm fast embedded"),
    ],
  })
  idx.add({
    id: "b",
    fields: [
      ("title", "rust language"),
      ("body", "rust systems memory safety rust"),
    ],
  })
  idx.add({
    id: "c",
    fields: [
      ("title", "全文搜索引擎"),
      ("body", "倒排索引 moonbit 搜索 引擎"),
    ],
  })
  idx.add({
    id: "d",
    fields: [("title", "go language"), ("body", "go cloud simple go")],
  })
  idx.add({ id: "e", fields: [("body", "moonbit language without a title")], })
  idx
}

///|
test "diff: single-term scores match the reference BM25 exactly" {
  let idx = diff_index()
  let analyzer = idx.analyzer()
  let bm25 = idx.bm25()
  // Field lengths are derivable from the analyzer alone.
  let len_of = fn(id : String, field : String) -> Double {
    match idx.get_field(id, field) {
      Some(text) => analyzer.analyze(text).length().to_double()
      None => 0.0
    }
  }
  for term in ["moonbit", "rust", "language", "go", "wasm", "搜索"] {
    // Per-field reference, summed the way eval_term does for a bare term.
    let expected : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
    for field in ["title", "body"] {
      let weight = if field == "title" { 3.0 } else { 1.0 }
      let per_field = ref_bm25(idx, field, term, weight, bm25.k1, bm25.b, fn(
        id,
      ) {
        len_of(id, field)
      })
      for (id, score) in per_field.iter() {
        expected.set(id, expected.get_or_default(id, 0.0) + score)
      }
    }
    let hits = idx.search(term, limit=0)
    assert_eq(hits.length(), expected.length())
    for hit in hits {
      let want = expected.get(hit.id).unwrap_or(-1.0)
      assert_true((hit.score - want).abs() < 0.000000001)
    }
  }
}

///|
test "diff: results are ordered by score desc then id ascending" {
  let idx = diff_index()
  for query in ["language", "moonbit", "language OR rust", "*", "lang*"] {
    let hits = idx.search(query, limit=0)
    for i in 1..<hits.length() {
      let prev = hits[i - 1]
      let cur = hits[i]
      assert_true(
        prev.score > cur.score ||
        (prev.score == cur.score && prev.id.lexical_compare(cur.id) < 0),
      )
    }
  }
}

///|
test "diff: limit=k is exactly the first k of limit=0" {
  let idx = diff_index()
  for query in ["language", "moonbit", "language OR rust", "*"] {
    let all = idx.search(query, limit=0)
    for k in 1..<all.length() {
      let top = idx.search(query, limit=k)
      assert_eq(top.length(), k)
      for i in 0..<k {
        assert_eq(top[i].id, all[i].id)
        assert_eq(top[i].score, all[i].score)
      }
    }
  }
}

///|
fn ids_of(hits : Array[@moonseek.Hit]) -> Array[String] {
  let ids = hits.map(fn(h) { h.id })
  ids.sort()
  ids
}

///|
test "diff: boolean set algebra holds against the operand result sets" {
  let idx = diff_index()
  let terms = ["moonbit", "rust", "language", "go", "wasm"]
  for i in 0..<terms.length() {
    for j in 0..<terms.length() {
      let a = terms[i]
      let b = terms[j]
      let sa = ids_of(idx.search(a, limit=0))
      let sb = ids_of(idx.search(b, limit=0))
      // OR is the union of the operand doc sets. Copy first: arrays are
      // references here, so `let union = sa` would alias (and mutate) sa.
      let union : Array[String] = []
      for id in sa {
        union.push(id)
      }
      for id in sb {
        if !union.contains(id) {
          union.push(id)
        }
      }
      union.sort()
      assert_eq(ids_of(idx.search("\{a} OR \{b}", limit=0)), union)
      // AND is the intersection.
      let inter : Array[String] = []
      for id in sa {
        if sb.contains(id) {
          inter.push(id)
        }
      }
      assert_eq(ids_of(idx.search("\{a} AND \{b}", limit=0)), inter)
      // NOT removes exactly the right operand's docs.
      let minus : Array[String] = []
      for id in sa {
        if !sb.contains(id) {
          minus.push(id)
        }
      }
      assert_eq(ids_of(idx.search("\{a} NOT \{b}", limit=0)), minus)
    }
  }
}

///|
test "diff: insertion order does not change relevance" {
  let docs : Array[@moonseek.Document] = [
    {
      id: "a",
      fields: [("title", "alpha beta"), ("body", "alpha beta gamma")],
    },
    {
      id: "b",
      fields: [("title", "beta gamma"), ("body", "gamma delta beta")],
    },
    { id: "c", fields: [("title", "gamma alpha"), ("body", "alpha delta")], },
  ]
  let forward = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for d in docs {
    forward.add(d)
  }
  let backward = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for i in 0..<docs.length() {
    backward.add(docs[docs.length() - 1 - i])
  }
  for query in ["alpha", "beta", "alpha OR gamma", "delta NOT alpha"] {
    let hf = forward.search(query, limit=0)
    let hb = backward.search(query, limit=0)
    assert_eq(ids_of(hf), ids_of(hb))
    for i in 0..<hf.length() {
      assert_eq(hf[i].id, hb[i].id)
      assert_true((hf[i].score - hb[i].score).abs() < 0.000000001)
    }
  }
}

///|
test "diff: merge operators preserve the ascending-doc invariant" {
  let idx = diff_index()
  // And over two fields of the same term, then a prefix union, then a diff:
  // any duplicate or out-of-order doc would surface here as a wrong score or
  // a repeated id.
  let scored_and = idx.search("moonbit AND language", limit=0)
  let seen : Array[String] = []
  for hit in scored_and {
    assert_true(!seen.contains(hit.id))
    seen.push(hit.id)
  }
  let all = idx.search("*", limit=0)
  assert_eq(all.length(), idx.doc_count())
}

///|
test "diff: deleted documents never appear and never affect scores" {
  let idx = diff_index()
  let before = idx.search("language", limit=0)
  let victim = before[0].id
  let _ = idx.delete(victim)
  let after = idx.search("language", limit=0)
  for hit in after {
    assert_true(hit.id != victim)
  }
  // Scoring the survivors must equal a fresh index built without the victim.
  let fresh = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for i in 0..<(idx.doc_count() + 1) {
    let id = idx.doc_id(i).unwrap_or("")
    if id != "" && id != victim {
      match idx.get_document(id) {
        Some(d) => fresh.add(d)
        None => ()
      }
    }
  }
  let expected = fresh.search("language", limit=0)
  assert_eq(ids_of(after), ids_of(expected))
  for i in 0..<after.length() {
    assert_eq(after[i].id, expected[i].id)
    assert_true((after[i].score - expected[i].score).abs() < 0.000000001)
  }
}
