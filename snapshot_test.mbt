///|
fn populated_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [
      ("title", "MoonBit programming language"),
      ("body", "MoonBit is a fast language for WebAssembly"),
    ],
  })
  idx.add({
    id: "d2",
    fields: [
      ("title", "全文搜索引擎"),
      ("body", "倒排索引是搜索引擎的核心"),
    ],
  })
  idx.add({
    id: "d3",
    fields: [("title", "temporary"), ("body", "will be deleted")],
  })
  let _ = idx.delete("d3")
  idx
}

///|
test "snapshot roundtrip preserves search results" {
  let idx = populated_index()
  let image = idx.to_bytes()
  let restored = @moonseek.Index::from_bytes(image)
  assert_eq(restored.doc_count(), 2)
  // Same queries, same hits, same scores.
  for query in ["moonbit", "搜索引擎", "language NOT rust", "*", "prog*"] {
    let original = idx.search(query, limit=0)
    let after = restored.search(query, limit=0)
    assert_eq(original.length(), after.length())
    for i in 0..<original.length() {
      assert_eq(original[i].id, after[i].id)
      assert_eq(original[i].score, after[i].score)
    }
  }
}

///|
test "snapshot is deterministic" {
  let idx = populated_index()
  assert_eq(idx.to_bytes(), idx.to_bytes())
}

///|
test "snapshot detects bit corruption" {
  let idx = populated_index()
  let image = idx.to_bytes()
  // Flip a byte in the middle of the payload.
  let corrupted = image.to_array()
  let mid = corrupted.length() / 2
  corrupted[mid] = (corrupted[mid].to_int() ^ 0xFF).to_byte()
  let result = @moonseek.Index::from_bytes(Bytes::from_array(corrupted[:])) catch {
    e => {
      assert_true(e is @moonseek.CodecError::CrcMismatch(_, _))
      return ()
    }
  }
  let _ = result
  fail("corruption should have been detected")
}

///|
test "snapshot detects truncation" {
  let idx = populated_index()
  let image = idx.to_bytes()
  let truncated = image.clamped_view(end=image.length() - 3).to_owned()
  let result = @moonseek.Index::from_bytes(truncated) catch {
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
test "snapshot rejects bad magic" {
  let result = @moonseek.Index::from_bytes(b"XXXXXXXX") catch {
    e => {
      assert_true(e is @moonseek.CodecError::BadMagic)
      return ()
    }
  }
  let _ = result
  fail("bad magic should have been rejected")
}

///|
test "empty index roundtrip" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  assert_eq(restored.doc_count(), 0)
  assert_eq(restored.search("*").length(), 0)
}

///|
test "restored index accepts new documents" {
  let idx = populated_index()
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  restored.add({
    id: "new",
    fields: [("title", "fresh content"), ("body", "aardvark")],
  })
  assert_eq(restored.doc_count(), 3)
  let hits = restored.search("aardvark")
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].id, "new")
}
