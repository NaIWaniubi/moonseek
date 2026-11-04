///|
test "stored fields roundtrip through snapshot" {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [("title", "全文搜索引擎"), ("body", "倒排索引是核心")],
  })
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  let doc = restored.get_document("d1")
  assert_true(doc is Some(_))
  match doc {
    Some(d) => {
      assert_eq(d.id, "d1")
      assert_eq(d.fields.length(), 2)
    }
    None => fail("document should exist")
  }
  assert_eq(restored.get_field("d1", "title"), Some("全文搜索引擎"))
  assert_eq(restored.get_field("d1", "body"), Some("倒排索引是核心"))
  assert_eq(restored.get_field("d1", "nonexistent"), None)
  assert_eq(restored.get_field("unknown", "title"), None)
}

///|
test "deleted document has no stored fields" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello")], })
  let _ = idx.delete("a")
  assert_eq(idx.get_document("a"), None)
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  assert_eq(restored.get_document("a"), None)
}

///|
test "replaced document stores new text" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "old text")], })
  idx.add({ id: "a", fields: [("body", "new text")], })
  assert_eq(idx.get_field("a", "body"), Some("new text"))
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  assert_eq(restored.get_field("a", "body"), Some("new text"))
}

///|
test "schema and analyzer accessors" {
  let idx = @moonseek.Index::new(
    [{ name: "title", weight: 2.5, }, { name: "body", weight: 1.0, }],
    analyzer={ lowercase: false, remove_stop_words: false, cjk_bigram: true, },
  )
  assert_eq(idx.schema().length(), 2)
  assert_eq(idx.schema()[0].weight, 2.5)
  assert_eq(idx.analyzer().lowercase, false)
  idx.add({ id: "x", fields: [("body", "hello hello world")], })
  assert_eq(idx.doc_freq("body", "hello"), 1)
  assert_eq(idx.doc_freq("body", "absent"), 0)
}
