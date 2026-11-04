///|
/// Tests for the segmented index: freezing, cross-segment search/delete,
/// newest-wins updates, tiered merge, and the MSKS container snapshot.

///|
fn seg_schema() -> Array[@moonseek.FieldSchema] {
  [{ name: "title", weight: 3.0, }, { name: "body", weight: 1.0, }]
}

///|
fn seg_doc(id : String, text : String) -> @moonseek.Document {
  { id, fields: [("title", text), ("body", text)], }
}

///|
fn sorted_ids(hits : Array[@moonseek.Hit]) -> Array[String] {
  let ids = hits.map(fn(h) { h.id })
  ids.sort()
  ids
}

///|
test "segment: freeze at threshold" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=3)
  seg.add(seg_doc("a", "alpha"))
  seg.add(seg_doc("b", "beta"))
  // Active segment holds 2 docs: counted, but not yet frozen.
  assert_eq(seg.segment_count(), 1)
  seg.add(seg_doc("c", "gamma"))
  // Threshold reached: active frozen, new active is empty (not counted).
  assert_eq(seg.segment_count(), 1)
  seg.add(seg_doc("d", "delta"))
  assert_eq(seg.segment_count(), 2)
  seg.add(seg_doc("e", "epsilon"))
  seg.add(seg_doc("f", "zeta"))
  assert_eq(seg.segment_count(), 2)
  assert_eq(seg.doc_count(), 6)
}

///|
test "segment: flush freezes active segment once" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema())
  seg.add(seg_doc("a", "alpha"))
  seg.flush()
  assert_eq(seg.segment_count(), 1)
  seg.flush()
  assert_eq(seg.segment_count(), 1)
  assert_eq(seg.doc_count(), 1)
}

///|
test "segment: cross-segment search finds all segments" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit language"))
  seg.add(seg_doc("b", "rust language"))
  seg.add(seg_doc("c", "python language"))
  seg.add(seg_doc("d", "ocaml language"))
  seg.add(seg_doc("e", "haskell language"))
  // Two frozen segments plus the active one holding "e".
  assert_eq(seg.segment_count(), 3)
  let hits = seg.search("language", limit=0)
  assert_eq(sorted_ids(hits), ["a", "b", "c", "d", "e"])
  assert_eq(sorted_ids(seg.search("moonbit")), ["a"])
  assert_eq(sorted_ids(seg.search("ocaml")), ["d"])
  assert_eq(sorted_ids(seg.search("haskell")), ["e"])
}

///|
test "segment: delete spans segments" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit"))
  seg.add(seg_doc("b", "rust"))
  seg.add(seg_doc("c", "moonbit"))
  seg.add(seg_doc("d", "rust"))
  seg.add(seg_doc("e", "moonbit"))
  assert_true(seg.delete("a"))
  assert_true(seg.delete("c"))
  assert_eq(seg.doc_count(), 3)
  assert_eq(sorted_ids(seg.search("moonbit")), ["e"])
  assert_eq(sorted_ids(seg.search("rust", limit=0)), ["b", "d"])
  // Index::delete semantics: a tombstoned id still "existed" (doc_nums
  // keeps the entry), so a repeated delete returns true. Only ids never
  // seen return false.
  assert_true(seg.delete("a"))
  assert_true(!seg.delete("missing"))
}

///|
test "segment: update across segments keeps newest version" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "old content zebra"))
  seg.add(seg_doc("b", "filler"))
  // a is now frozen; re-add goes to the active segment
  seg.add(seg_doc("a", "new content walrus"))
  assert_eq(seg.doc_count(), 2)
  // Search resolves to the newest version: terms that only existed in
  // the old (frozen) version must NOT match, exactly like a single index.
  assert_eq(seg.search("zebra").length(), 0)
  assert_eq(seg.get_document("a"), Some(seg_doc("a", "new content walrus")))
  assert_eq(sorted_ids(seg.search("walrus")), ["a"])
  // A delete after an update must hide every version.
  assert_true(seg.delete("a"))
  assert_eq(seg.search("walrus").length(), 0)
  assert_eq(seg.doc_count(), 1)
}

///|
test "segment: delete then re-add resurrects document" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit"))
  seg.add(seg_doc("b", "filler"))
  assert_true(seg.delete("a"))
  assert_eq(seg.doc_count(), 1)
  seg.add(seg_doc("a", "moonbit returns"))
  assert_eq(seg.doc_count(), 2)
  assert_eq(sorted_ids(seg.search("moonbit")), ["a"])
}

///|
test "segment: merge reduces segment count and keeps results" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit language"))
  seg.add(seg_doc("b", "rust language"))
  seg.add(seg_doc("c", "python language"))
  seg.add(seg_doc("d", "ocaml language"))
  seg.add(seg_doc("e", "haskell language"))
  assert_eq(seg.segment_count(), 3)
  let before = sorted_ids(seg.search("language", limit=0))
  seg.merge(max_segments=1)
  assert_eq(seg.segment_count(), 1)
  assert_eq(seg.doc_count(), 5)
  assert_eq(sorted_ids(seg.search("language", limit=0)), before)
  assert_eq(sorted_ids(seg.search("moonbit")), ["a"])
  assert_eq(sorted_ids(seg.search("haskell")), ["e"])
  // The active segment was folded into the merge result.
  seg.add(seg_doc("f", "fresh language"))
  assert_eq(sorted_ids(seg.search("fresh")), ["f"])
}

///|
test "segment: merge deduplicates updated ids keeping newest" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "old zebra"))
  seg.add(seg_doc("b", "filler one"))
  seg.add(seg_doc("a", "new walrus"))
  seg.add(seg_doc("c", "filler two"))
  seg.add(seg_doc("d", "filler three"))
  seg.merge(max_segments=1)
  assert_eq(seg.doc_count(), 4)
  assert_eq(seg.search("zebra").length(), 0)
  assert_eq(sorted_ids(seg.search("walrus")), ["a"])
}

///|
test "segment: merge drops deleted documents entirely" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit"))
  seg.add(seg_doc("b", "rust"))
  seg.add(seg_doc("c", "moonbit"))
  seg.add(seg_doc("d", "rust"))
  seg.add(seg_doc("e", "moonbit"))
  assert_true(seg.delete("c"))
  seg.merge(max_segments=1)
  assert_eq(seg.doc_count(), 4)
  assert_eq(sorted_ids(seg.search("moonbit", limit=0)), ["a", "e"])
  assert_true(!seg.delete("c"))
}

///|
test "segment: merge is idempotent at the cap" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "alpha"))
  seg.add(seg_doc("b", "beta"))
  seg.add(seg_doc("c", "gamma"))
  seg.add(seg_doc("d", "delta"))
  seg.add(seg_doc("e", "epsilon"))
  seg.merge(max_segments=1)
  let first = seg.to_bytes()
  seg.merge(max_segments=1)
  assert_eq(seg.segment_count(), 1)
  assert_eq(seg.doc_count(), 5)
  assert_eq(seg.to_bytes(), first)
}

///|
test "segment: tiered merge keeps sizes balanced" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  for i in 0..<16 {
    seg.add(seg_doc("d\{i}", "common term number \{i}"))
  }
  assert_eq(seg.segment_count(), 8)
  seg.merge()
  // 16 live docs, default cap 4: a single size-16 segment is enough.
  assert_true(seg.segment_count() <= 4)
  assert_eq(seg.doc_count(), 16)
  assert_eq(seg.search("common", limit=0).length(), 16)
}

///|
test "segment: merge preserves newest-wins across untouched segments" {
  // Regression: a rebuilt segment must not shadow a newer version of
  // the same id living in an UNTOUCHED segment. Layout (max_docs=100 so
  // nothing auto-freezes; explicit flushes make the tiers exact):
  //   s0 (2 docs, class 1): a_OLD + f        — chosen, contains stale "a"
  //   s1 (2 docs, class 1): b, c             — chosen
  //   s2 (4 docs, class 2): a_NEW + fillers  — untouched, newest "a"
  // merge(max_segments=2) collapses the fullest tier (class 1: s0+s1).
  // Without tombstoning ids that also live in untouched newer segments,
  // the rebuild's a_OLD would shadow s2's a_NEW.
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=100)
  seg.add(seg_doc("a", "version one zebra"))
  seg.add(seg_doc("f", "filler f"))
  seg.flush()
  seg.add(seg_doc("b", "filler b"))
  seg.add(seg_doc("c", "filler c"))
  seg.flush()
  seg.add(seg_doc("a", "version two walrus"))
  seg.add(seg_doc("x1", "filler"))
  seg.add(seg_doc("x2", "filler"))
  seg.add(seg_doc("x3", "filler"))
  seg.flush()
  seg.merge(max_segments=2)
  assert_eq(seg.segment_count(), 2)
  assert_eq(seg.doc_count(), 7)
  assert_eq(seg.get_document("a"), Some(seg_doc("a", "version two walrus")))
  assert_eq(seg.search("zebra").length(), 0)
  assert_eq(sorted_ids(seg.search("walrus")), ["a"])
}

///|
test "segment: snapshot roundtrip preserves everything" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "moonbit language"))
  seg.add(seg_doc("b", "全文搜索引擎"))
  seg.add(seg_doc("c", "rust language"))
  seg.add(seg_doc("d", "倒排索引"))
  seg.add(seg_doc("e", "active segment doc"))
  assert_true(seg.delete("c"))
  let image = seg.to_bytes()
  let restored = @moonseek.SegmentedIndex::from_bytes(image)
  assert_eq(restored.segment_count(), seg.segment_count())
  assert_eq(restored.doc_count(), 4)
  for
    query in [
      "moonbit", "搜索引擎", "倒排索引", "active", "*", "language",
    ] {
    assert_eq(
      sorted_ids(restored.search(query, limit=0)),
      sorted_ids(seg.search(query, limit=0)),
    )
  }
  assert_eq(seg.to_bytes(), image)
}

///|
test "segment: empty snapshot roundtrip" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema())
  let restored = @moonseek.SegmentedIndex::from_bytes(seg.to_bytes())
  assert_eq(restored.doc_count(), 0)
  assert_eq(restored.segment_count(), 0)
  restored.add(seg_doc("a", "after restore"))
  assert_eq(sorted_ids(restored.search("restore")), ["a"])
}

///|
test "segment: snapshot detects bit corruption" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema())
  seg.add(seg_doc("a", "moonbit"))
  let image = seg.to_bytes()
  let corrupted = image.to_array()
  let mid = corrupted.length() / 2
  corrupted[mid] = (corrupted[mid].to_int() ^ 0xFF).to_byte()
  let result = @moonseek.SegmentedIndex::from_bytes(
    Bytes::from_array(corrupted[:]),
  ) catch {
    e => {
      assert_true(e is @moonseek.CodecError::CrcMismatch(_, _))
      return ()
    }
  }
  let _ = result
  fail("corruption should have been detected")
}

///|
test "segment: snapshot rejects bad magic" {
  let result = @moonseek.SegmentedIndex::from_bytes(b"XXXXXXXX") catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadMagic)
      return ()
    }
  }
  let _ = result
  fail("bad magic should have been rejected")
}

///|
test "segment: snapshot detects truncation" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema())
  seg.add(seg_doc("a", "moonbit"))
  let image = seg.to_bytes()
  let truncated = image.clamped_view(end=image.length() - 5).to_owned()
  let result = @moonseek.SegmentedIndex::from_bytes(truncated) catch {
    e => {
      assert_true(
        e is @moonseek.CodecError::CrcMismatch(_, _) ||
        e is @moonseek.CodecError::UnexpectedEof,
      )
      return ()
    }
  }
  let _ = result
  fail("truncation should have been detected")
}

///|
test "segment: search matches single-index id sets" {
  let docs : Array[@moonseek.Document] = [
    seg_doc("d1", "MoonBit programming language"),
    seg_doc("d2", "Rust systems programming"),
    seg_doc("d3", "全文搜索引擎"),
    seg_doc("d4", "search search search engines"),
    seg_doc("d5", "倒排索引是搜索引擎的核心"),
    seg_doc("d6", "WebAssembly fast language"),
    seg_doc("d7", "memory safety systems"),
  ]
  let single = @moonseek.Index::new(seg_schema())
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  for doc in docs {
    single.add(doc)
    seg.add(doc)
  }
  // Scores may differ (per-segment IDF), but the id sets must agree.
  for
    query in [
      "moonbit", "rust", "搜索引擎", "倒排索引", "search", "language", "moonbit OR rust",
      "language NOT rust", "prog*", "*", "\"systems programming\"", "title:search",
    ] {
    let a = sorted_ids(single.search(query, limit=0))
    let b = sorted_ids(seg.search(query, limit=0))
    assert_eq(b, a)
  }
}

///|
test "segment: limit and tie-breaking are deterministic" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("z", "same words here"))
  seg.add(seg_doc("a", "same words here"))
  seg.add(seg_doc("m", "same words here"))
  seg.add(seg_doc("b", "same words here"))
  seg.add(seg_doc("q", "same words here"))
  let hits = seg.search("same", limit=3)
  assert_eq(hits.length(), 3)
  // Equal scores are broken by id, ascending.
  assert_eq(hits.map(fn(h) { h.id }), ["a", "b", "m"])
  let again = seg.search("same", limit=3)
  assert_eq(again, hits)
}

///|
test "segment: query errors propagate" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema())
  seg.add(seg_doc("a", "moonbit"))
  let result = seg.search("nonexistent:term") catch {
    e => {
      assert_true(e is @moonseek.QueryError::UnknownField(_))
      return ()
    }
  }
  let _ = result
  fail("unknown field should raise")
}

///|
test "segment: get_document returns newest live version" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "old text"))
  seg.add(seg_doc("b", "filler"))
  seg.add(seg_doc("a", "new text"))
  assert_eq(seg.get_document("a"), Some(seg_doc("a", "new text")))
  assert_true(seg.delete("a"))
  assert_eq(seg.get_document("a"), None)
  assert_eq(seg.get_document("missing"), None)
}

///|
test "segment: get_field reads newest live version" {
  let seg = @moonseek.SegmentedIndex::new(seg_schema(), segment_max_docs=2)
  seg.add(seg_doc("a", "old text"))
  seg.add(seg_doc("b", "filler"))
  seg.add(seg_doc("a", "new text"))
  assert_eq(seg.get_field("a", "title"), Some("new text"))
  assert_eq(seg.get_field("a", "nonexistent"), None)
  assert_eq(seg.get_field("missing", "title"), None)
  assert_true(seg.delete("a"))
  assert_eq(seg.get_field("a", "title"), None)
}
