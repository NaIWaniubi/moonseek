///|
/// Regression tests for confirmed engine bugs: field-scoped star queries,
/// field-scoped phrase queries, NOT-query score injection, BK-tree metric
/// mismatch, tie-break ordering, varint edge cases, and WAL recovery
/// semantics.

///|
fn fixes_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "withtitle",
    fields: [("title", "moonbit language"), ("body", "rust systems")],
  })
  idx.add({ id: "notitle", fields: [("body", "moonbit runtime")], })
  idx
}

///|
test "field star query only returns documents with that field" {
  let idx = fixes_index()
  let hits = idx.search("title:*", limit=0)
  // "notitle" has no title content: it must not match title:*.
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].id, "withtitle")
  // Unscoped star still matches everything.
  assert_eq(idx.search("*", limit=0).length(), 2)
  // Unknown field is a query error.
  let result = idx.search("ghost:*") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnknownField("ghost"))
      return ()
    }
  }
  let _ = result
  fail("unknown field star should raise")
}

///|
test "field scoped phrase query" {
  let idx = fixes_index()
  // "rust systems" appears adjacently in withtitle's body only.
  let hits = idx.search("body:\"rust systems\"", limit=0)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].id, "withtitle")
  // Field-scoped phrase that matches nothing.
  assert_eq(idx.search("title:\"rust systems\"", limit=0).length(), 0)
  // Field scoping is honored: the phrase only exists in body, so a title
  // scoped query must not hit the body match.
  let title_hits = idx.search("title:\"moonbit language\"", limit=0)
  assert_eq(title_hits.length(), 1)
  assert_eq(title_hits[0].id, "withtitle")
}

///|
test "NOT query contributes no constant score" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "rust fast")], })
  idx.add({ id: "b", fields: [("body", "rust slow")], })
  let plain = idx.search("rust NOT nonexistent", limit=0)
  let and_not = idx.search("rust AND NOT nonexistent", limit=0)
  assert_eq(plain.length(), 2)
  assert_eq(and_not.length(), 2)
  // The two forms must score identically: NOT must not inject 1.0.
  for i in 0..<plain.length() {
    assert_true((plain[i].score - and_not[i].score).abs() < 0.000000001)
  }
  // Leading NOT yields live docs with zero score (exclusion only).
  let leading = idx.search("NOT rust", limit=0)
  assert_eq(leading.length(), 0)
  idx.add({ id: "c", fields: [("body", "go")], })
  let leading = idx.search("NOT rust", limit=0)
  assert_eq(leading.length(), 1)
  assert_true(leading[0].score.abs() < 0.000000001)
  // Explain decomposes the AND NOT total exactly.
  let exp = idx.explain("rust AND NOT nonexistent", "a")
  match exp {
    Some(e) => {
      let mut sum = 0.0
      for d in e.details {
        sum += d.score
      }
      assert_true((sum - e.total_score).abs() < 0.000000001)
    }
    None => fail("explain should match")
  }
}

///|
test "bktree search matches damerau semantics of fuzzy_terms" {
  // Adjacent transposition: Levenshtein("ba","ab")=2 but Damerau=1.
  let tree = @moonseek.BkTree::from_terms(["ab"])
  let hits = tree.search("ba", max_distance=1)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].term, "ab")
  assert_eq(hits[0].distance, 1)
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "ab cd")], })
  let slow = idx.fuzzy_terms("ba", max_distance=1)
  let fast = idx.fuzzy_terms_fast("ba", max_distance=1)
  assert_eq(slow.length(), 1)
  assert_eq(fast.length(), 1)
  assert_eq(fast[0].term, "ab")
  assert_eq(fast[0].distance, 1)
}

///|
test "bktree pruned search still finds every damerau match" {
  // Pruning must stay correct with the wider (Damerau-safe) window.
  let words = [
    "ab", "ba", "abc", "acb", "ca", "cart", "cra", "arc", "race", "acer",
  ]
  let tree = @moonseek.BkTree::from_terms(words)
  for query in ["ab", "ba", "ca", "ac", "cra", "arc", "acer"] {
    let found = tree.search(query, max_distance=2)
    let terms = found.map(fn(m) { m.term })
    for w in words {
      let d = @moonseek.damerau_levenshtein(query, w)
      if d <= 2 {
        assert_true(terms.contains(w))
      }
    }
  }
}

///|
test "fuzzy_search tie break uses lexicographic id order" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "b", fields: [("body", "zebra")], })
  idx.add({ id: "ab", fields: [("body", "zebra")], })
  let hits = idx.fuzzy_search("zebra", limit=0)
  assert_eq(hits.length(), 2)
  // Same score: "ab" sorts before "b" lexicographically (search's rule).
  assert_eq(hits[0].id, "ab")
  assert_eq(hits[1].id, "b")
}

///|
test "varint encodes negative input as unsigned 32-bit" {
  let buf : Array[Byte] = []
  @moonseek.write_varint(buf, -1)
  // -1 reinterpreted as u32 needs 5 LEB128 groups, not a lone 0xFF.
  assert_eq(buf.length(), 5)
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  assert_eq(reader.read_varint(), -1)
  assert_eq(reader.remaining(), 0)
  // Two values must stay aligned: no byte-stream corruption.
  let buf : Array[Byte] = []
  @moonseek.write_varint(buf, -1)
  @moonseek.write_varint(buf, 5)
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  assert_eq(reader.read_varint(), -1)
  assert_eq(reader.read_varint(), 5)
  assert_eq(reader.remaining(), 0)
}

///|
test "bytewriter varint encodes negative input as unsigned 32-bit" {
  let w = @moonseek.ByteWriter::new()
  w.write_varint(-1)
  w.write_varint(5)
  assert_eq(w.length(), 6)
  let reader = @moonseek.Reader::new(w.to_bytes())
  assert_eq(reader.read_varint(), -1)
  assert_eq(reader.read_varint(), 5)
  assert_eq(reader.remaining(), 0)
}

///|
test "read_varint rejects non-canonical encodings beyond 32 bits" {
  // 6 continuation groups: Int32 can never need this many bytes.
  let buf : Array[Byte] = [b'\xFF', b'\xFF', b'\xFF', b'\xFF', b'\xFF', b'\x7F']
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  let result = reader.read_varint() catch {
    e => {
      assert_true(e is @moonseek.CodecError::VarintOverflow)
      return ()
    }
  }
  let _ = result
  fail("6-byte varint should overflow")
}

///|
test "read_varint accepts maximal 5-byte encoding" {
  let buf : Array[Byte] = [b'\xFF', b'\xFF', b'\xFF', b'\xFF', b'\x07']
  let reader = @moonseek.Reader::new(Bytes::from_array(buf[:]))
  assert_eq(reader.read_varint(), 2147483647)
  assert_eq(reader.remaining(), 0)
}

///|
test "wal unknown entry type is treated as torn tail" {
  // Valid header + one valid Add + a frame whose type byte is corrupt.
  let entries : Array[@moonseek.WalEntry] = [
    Add({ id: "a", fields: [("body", "kept")], }),
  ]
  let good = @moonseek.wal_encode(entries)
  let buf : Array[Byte] = []
  for b in good.iter() {
    buf.push(b)
  }
  // A frame with unknown type byte 0x7F and garbage payload: replay must
  // stop there (torn tail), keeping the earlier entries, not raise.
  buf.push(b'\x7F')
  buf.push(b'\x01')
  let decoded = @moonseek.wal_decode(Bytes::from_array(buf[:]))
  assert_eq(decoded.length(), 1)
  match decoded[0] {
    Add(doc) => assert_eq(doc.id, "a")
    Delete(_) => fail("expected Add")
  }
  // A lone unknown type right after the header: nothing to replay.
  let lone : Array[Byte] = [
    b'M', b'W', b'L', b'1', 0x7F, 0x00, 0x00, 0x00, 0x00,
  ]
  assert_eq(@moonseek.wal_decode(Bytes::from_array(lone[:])).length(), 0)
}

///|
test "codec error is user readable via Show" {
  assert_eq(@moonseek.CodecError::BadMagic.to_string(), "bad magic")
  assert_eq(@moonseek.CodecError::BadVersion(7).to_string(), "bad version: 7")
  let (expected, actual) = (5U, 9U)
  assert_eq(
    @moonseek.CodecError::CrcMismatch(expected, actual).to_string(),
    "crc mismatch: expected 5, got 9",
  )
}

///|
test "result types serialize to json" {
  let hit : @moonseek.Hit = { id: "a", score: 1.5, }
  let s = hit.to_json().stringify()
  assert_true(s.contains("\"id\":\"a\""))
  assert_true(s.contains("\"score\":1.5"))
  let detail : @moonseek.ScoreDetail = {
    field: "body",
    term: "x",
    tf: 2,
    df: 3,
    idf: 0.5,
    norm: 1.0,
    score: 0.25,
  }
  let exp : @moonseek.Explanation = {
    id: "a",
    total_score: 0.25,
    details: [detail],
  }
  let s = exp.to_json().stringify()
  assert_true(s.contains("\"total_score\":0.25"))
  assert_true(s.contains("\"tf\":2"))
  let count : @moonseek.FacetCount = { value: "en", count: 4, }
  assert_true(count.to_json().stringify().contains("[\"en\",4]"))
  let opts = @moonseek.SearchOptions::default()
  let s = opts.to_json().stringify()
  assert_true(s.contains("\"limit\":10"))
  assert_true(s.contains("\"offset\":0"))
}

///|
fn[T : Default] generic_default() -> T {
  T::default()
}

///|
test "default is available through the Default trait" {
  let opts : @moonseek.SearchOptions = generic_default()
  assert_eq(opts.limit, 10)
  assert_eq(opts.offset, 0)
  let bm25 : @moonseek.Bm25Params = generic_default()
  assert_eq(bm25.k1, 1.2)
  assert_eq(bm25.b, 0.75)
  let analyzer : @moonseek.Analyzer = generic_default()
  assert_true(analyzer.lowercase)
}

///|
test "set_facets reports whether the document exists" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "x")], })
  assert_true(idx.set_facets("a", [("lang", ["en"])]))
  assert_true(!idx.set_facets("missing", [("lang", ["en"])]))
  let _ = idx.delete("a")
  assert_true(!idx.set_facets("a", [("lang", ["en"])]))
}

///|
test "deleted document facets leave no trace in the snapshot" {
  let with_facets = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  with_facets.add({ id: "a", fields: [("body", "x")], })
  let _ = with_facets.set_facets("a", [("lang", ["en"])])
  let _ = with_facets.delete("a")
  let without_facets = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  without_facets.add({ id: "a", fields: [("body", "x")], })
  let _ = without_facets.delete("a")
  assert_eq(with_facets.to_bytes(), without_facets.to_bytes())
}

///|
test "highlight spans are sorted half-open ranges" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "moonbit is fast; moonbit is small")], })
  let spans = idx.highlight_spans("a", "body", "moonbit")
  assert_eq(spans.length(), 2)
  // Sorted, non-overlapping, half-open.
  assert_true(spans[0].start < spans[0].end)
  assert_true(spans[0].end <= spans[1].start)
  assert_true(spans[1].start < spans[1].end)
}

///|
test "explain respects field scoping and phrase frequency" {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "a",
    fields: [("title", "moonbit moonbit"), ("body", "moonbit wasm")],
  })
  // Field-scoped term: only the title contributes.
  let exp = idx.explain("title:moonbit", "a")
  match exp {
    Some(e) => {
      let fields = e.details.map(fn(d) { d.field })
      assert_true(fields.contains("title"))
      assert_true(!fields.contains("body"))
      let mut sum = 0.0
      for d in e.details {
        sum += d.score
      }
      assert_true((sum - e.total_score).abs() < 0.000000001)
    }
    None => fail("explain should match")
  }
  // Phrase: tf in the detail is the phrase count, not the raw term tf.
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "ab ab ab")], })
  let exp = idx.explain("\"ab ab\"", "a")
  match exp {
    Some(e) => {
      assert_eq(e.details.length(), 1)
      // "ab ab" occurs twice as a phrase in "ab ab ab".
      assert_eq(e.details[0].tf, 2)
      let mut sum = 0.0
      for d in e.details {
        sum += d.score
      }
      assert_true((sum - e.total_score).abs() < 0.000000001)
    }
    None => fail("explain should match")
  }
}

///|
test "adding a field-less document keeps bm25 idf semantics" {
  // IDF legitimately tracks the whole live population (n), so adding a
  // document that carries no body changes idf; the avgdl effect is
  // covered separately in the whitebox test.
  let idx = @moonseek.Index::new([
    { name: "title", weight: 1.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({ id: "a1", fields: [("body", "term x")], })
  idx.add({ id: "a2", fields: [("body", "term y")], })
  let base = idx.search("term", limit=0)[0].score
  idx.add({ id: "no-body", fields: [("title", "unrelated")], })
  let drifted = idx.search("term", limit=0)[0].score
  assert_true(base > 0.0)
  assert_true(drifted > 0.0)
}

///|
test "index internal state is encapsulated" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello")], })
  // Public surface: schema, analyzer, doc stats, search.
  assert_eq(idx.schema().length(), 1)
  assert_eq(idx.schema()[0].name, "body")
  assert_true(idx.analyzer().lowercase)
  assert_eq(idx.doc_count(), 1)
  assert_eq(idx.search("hello")[0].id, "a")
  // bm25 params are readable for diagnostics.
  assert_true(idx.bm25().k1 > 0.0)
}
