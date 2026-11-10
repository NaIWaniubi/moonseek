///|
fn facet_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [("title", "MoonBit guide"), ("body", "language wasm")],
  })
  idx.add({
    id: "d2",
    fields: [("title", "Rust guide"), ("body", "language systems")],
  })
  idx.add({
    id: "d3",
    fields: [("title", "搜索引擎"), ("body", "倒排索引 language")],
  })
  idx.add({
    id: "d4",
    fields: [("title", "Go guide"), ("body", "language cloud")],
  })
  let _ = idx.set_facets("d1", [
    ("lang", ["en"]),
    ("topic", ["moonbit", "wasm"]),
  ])
  let _ = idx.set_facets("d2", [("lang", ["en"]), ("topic", ["rust"])])
  let _ = idx.set_facets("d3", [("lang", ["zh"]), ("topic", ["search"])])
  let _ = idx.set_facets("d4", [("lang", ["en"]), ("topic", ["go", "cloud"])])
  idx
}

///|
test "facet: set and get" {
  let idx = facet_index()
  let f = idx.get_facets("d1")
  assert_eq(f.length(), 2)
  assert_eq(idx.get_facets("nonexistent").length(), 0)
}

///|
test "facet: filter by single value" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "lang", values: ["zh"], }],
    facet_fields: [],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 1)
  assert_eq(result.hits[0].id, "d3")
}

///|
test "facet: filter OR within field" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "topic", values: ["moonbit", "rust"], }],
    facet_fields: [],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 2)
}

///|
test "facet: filter AND across fields" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [
      { field: "lang", values: ["en"], },
      { field: "topic", values: ["wasm"], },
    ],
    facet_fields: [],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 1)
  assert_eq(result.hits[0].id, "d1")
}

///|
test "facet: aggregation counts" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [],
    facet_fields: ["lang", "topic"],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 4)
  assert_eq(result.facets.length(), 2)
  // lang: en=3, zh=1
  let lang_facets = result.facets[0].1
  assert_eq(lang_facets[0].value, "en")
  assert_eq(lang_facets[0].count, 3)
  assert_eq(lang_facets[1].value, "zh")
  assert_eq(lang_facets[1].count, 1)
}

///|
test "facet: aggregation respects filters" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "lang", values: ["en"], }],
    facet_fields: ["topic"],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 3)
  // topic counts only among en docs
  let topics = result.facets[0].1
  let mut total_count = 0
  for fc in topics {
    total_count += fc.count
  }
  // d1 has 2 topics, d2 has 1, d4 has 2 = 5
  assert_eq(total_count, 5)
}

///|
test "facet: pagination offset" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 2,
    offset: 1,
    filters: [],
    facet_fields: [],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 4)
  assert_eq(result.hits.length(), 2)
}

///|
test "facet: offset beyond total returns empty" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 100,
    filters: [],
    facet_fields: [],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 4)
  assert_eq(result.hits.length(), 0)
}

///|
test "facet: deleted doc excluded from facets" {
  let idx = facet_index()
  let _ = idx.delete("d1")
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [],
    facet_fields: ["lang"],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 3)
  let lang = result.facets[0].1
  // en=2 (d2,d4), zh=1 (d3)
  assert_eq(lang[0].count, 2)
}

///|
test "facet: no filters no facets = plain search" {
  let idx = facet_index()
  let result = idx.search_faceted("language")
  assert_eq(result.total, 4)
  assert_eq(result.facets.length(), 0)
}

///|
test "facet: multi-value facet counts each value" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [],
    facet_fields: ["topic"],
  }
  let result = idx.search_faceted("language", options=opts)
  let topics = result.facets[0].1
  // d1: moonbit+wasm, d2: rust, d3: search, d4: go+cloud = 6 values
  let mut total = 0
  for fc in topics {
    total += fc.count
  }
  assert_eq(total, 6)
}

///|
test "facet: filter with no match returns zero" {
  let idx = facet_index()
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "lang", values: ["fr"], }],
    facet_fields: ["topic"],
  }
  let result = idx.search_faceted("language", options=opts)
  assert_eq(result.total, 0)
  assert_eq(result.hits.length(), 0)
  assert_eq(result.facets[0].1.length(), 0)
}
