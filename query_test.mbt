///|
fn sample_index() -> @moonseek.Index {
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
      ("title", "Rust programming"),
      ("body", "Rust is a systems language with memory safety"),
    ],
  })
  idx.add({
    id: "d3",
    fields: [
      ("title", "全文搜索引擎"),
      ("body", "倒排索引是搜索引擎的核心"),
    ],
  })
  idx.add({
    id: "d4",
    fields: [("title", "Search engines"), ("body", "search search search")],
  })
  idx
}

///|
fn hit_ids(hits : Array[@moonseek.Hit]) -> Array[String] {
  hits.map(fn(h) { h.id })
}

///|
test "single term search" {
  let idx = sample_index()
  let hits = idx.search("moonbit")
  assert_eq(hit_ids(hits), ["d1"])
}

///|
test "implicit AND" {
  let idx = sample_index()
  let hits = idx.search("rust memory")
  assert_eq(hit_ids(hits), ["d2"])
}

///|
test "OR query" {
  let idx = sample_index()
  let hits = idx.search("moonbit OR rust")
  assert_eq(hit_ids(hits).length(), 2)
  assert_true(hit_ids(hits).contains("d1"))
  assert_true(hit_ids(hits).contains("d2"))
}

///|
test "NOT query" {
  let idx = sample_index()
  let hits = idx.search("language NOT rust")
  assert_eq(hit_ids(hits), ["d1"])
}

///|
test "field scoped query" {
  let idx = sample_index()
  let hits = idx.search("title:rust")
  assert_eq(hit_ids(hits), ["d2"])
  let body_hits = idx.search("body:moonbit")
  assert_eq(hit_ids(body_hits), ["d1"])
}

///|
test "phrase query english" {
  let idx = sample_index()
  let hits = idx.search("\"systems language\"")
  assert_eq(hit_ids(hits), ["d2"])
  let no_match = idx.search("\"language systems\"")
  assert_eq(no_match.length(), 0)
}

///|
test "chinese search via bigrams" {
  let idx = sample_index()
  let hits = idx.search("搜索引擎")
  assert_eq(hit_ids(hits), ["d3"])
  let hits2 = idx.search("倒排索引")
  assert_eq(hit_ids(hits2), ["d3"])
}

///|
test "chinese phrase query" {
  let idx = sample_index()
  let hits = idx.search("\"搜索引擎\"")
  assert_eq(hit_ids(hits), ["d3"])
}

///|
test "prefix query" {
  let idx = sample_index()
  let hits = idx.search("prog*")
  assert_eq(hit_ids(hits).length(), 2)
  assert_true(hit_ids(hits).contains("d1"))
  assert_true(hit_ids(hits).contains("d2"))
}

///|
test "match all" {
  let idx = sample_index()
  let hits = idx.search("*", limit=0)
  assert_eq(hits.length(), 4)
}

///|
test "bm25 ranks higher term frequency first" {
  let idx = sample_index()
  let hits = idx.search("search")
  // d4 has "search" 4 times (title+body), d3 body has it via bigram only
  assert_true(hits.length() >= 1)
  assert_eq(hits[0].id, "d4")
}

///|
test "field weight boosts title matches" {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 10.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({ id: "a", fields: [("title", "zebra"), ("body", "horse")], })
  idx.add({ id: "b", fields: [("title", "horse"), ("body", "zebra")], })
  let hits = idx.search("zebra")
  assert_eq(hits[0].id, "a")
}

///|
test "delete removes from results" {
  let idx = sample_index()
  assert_true(idx.delete("d1"))
  let hits = idx.search("moonbit")
  assert_eq(hits.length(), 0)
  assert_eq(idx.doc_count(), 3)
  assert_true(!idx.delete("nonexistent"))
}

///|
test "re-add replaces document" {
  let idx = sample_index()
  idx.add({
    id: "d1",
    fields: [("title", "completely different"), ("body", "now about turtles")],
  })
  assert_eq(idx.search("moonbit").length(), 0)
  assert_eq(hit_ids(idx.search("turtles")), ["d1"])
  assert_eq(idx.doc_count(), 4)
}

///|
test "limit caps results" {
  let idx = sample_index()
  let hits = idx.search("*", limit=2)
  assert_eq(hits.length(), 2)
}

///|
fn search_fails(idx : @moonseek.Index, query : String) -> Bool {
  try {
    let _ = idx.search(query)
    false
  } catch {
    _ => true
  }
}

///|
test "parse errors" {
  let idx = sample_index()
  assert_true(search_fails(idx, ""))
  assert_true(search_fails(idx, "\"unterminated"))
  assert_true(search_fails(idx, "nonexistent:term"))
  assert_true(search_fails(idx, "(moonbit"))
}

///|
test "parenthesized boolean" {
  let idx = sample_index()
  let hits = idx.search("(moonbit OR rust) AND language")
  assert_eq(hit_ids(hits).length(), 2)
}

///|
test "leading NOT" {
  let idx = sample_index()
  let hits = idx.search("NOT language", limit=0)
  // d3 (chinese) and d4 (search engines) don't contain "language"
  assert_eq(hits.length(), 2)
}
