///|
test "facet: snapshot roundtrip preserves facets" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello world")], })
  idx.add({ id: "b", fields: [("body", "全文搜索")], })
  let _ = idx.set_facets("a", [("lang", ["en"]), ("topic", ["greeting"])])
  let _ = idx.set_facets("b", [
    ("lang", ["zh"]),
    ("topic", ["search", "engine"]),
  ])
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  let fa = restored.get_facets("a")
  assert_eq(fa.length(), 2)
  let fb = restored.get_facets("b")
  assert_eq(fb.length(), 2)
  // Faceted search works after roundtrip
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "lang", values: ["zh"], }],
    facet_fields: ["topic"],
  }
  let result = restored.search_faceted("搜索", options=opts)
  assert_eq(result.total, 1)
  assert_eq(result.hits[0].id, "b")
  assert_eq(result.facets[0].1.length(), 2)
}

///|
test "facet: deleted doc facets excluded after roundtrip" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "hello")], })
  let _ = idx.set_facets("a", [("lang", ["en"])])
  let _ = idx.delete("a")
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  assert_eq(restored.get_facets("a").length(), 0)
}
