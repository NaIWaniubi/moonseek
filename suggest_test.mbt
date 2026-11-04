///|
/// Corpus where "search" is common, "sears" is rare, and "research" exists.
fn suggest_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [("title", "search engine"), ("body", "search search search")],
  })
  idx.add({
    id: "d2",
    fields: [("title", "search tools"), ("body", "search engines")],
  })
  idx.add({
    id: "d3",
    fields: [("title", "search guide"), ("body", "how to search")],
  })
  idx.add({
    id: "d6",
    fields: [("title", "search reference"), ("body", "search engines")],
  })
  idx.add({ id: "d4", fields: [("body", "sears catalog")], })
  idx.add({ id: "d5", fields: [("body", "research papers")], })
  idx
}

///|
test "suggest corrects a misspelled single word" {
  let idx = suggest_index()
  assert_eq(idx.suggest("serch"), Some("search"))
}

///|
test "suggest returns None for an exact dictionary word" {
  let idx = suggest_index()
  assert_eq(idx.suggest("search"), None)
  assert_eq(idx.suggest("research"), None)
}

///|
test "suggest returns None when nothing is close" {
  let idx = suggest_index()
  assert_eq(idx.suggest("zzzzzzzz"), None)
  assert_eq(idx.suggest(""), None)
  assert_eq(idx.suggest("   "), None)
}

///|
test "suggest prefers the candidate with higher document frequency" {
  let idx = suggest_index()
  // "serch" is distance 1 from both "search" (df=3) and "sears" (df=1).
  // Even though both are distance 1, the common word wins.
  assert_eq(idx.suggest("serch"), Some("search"))
}

///|
test "suggest corrects only the first correctable word" {
  let idx = suggest_index()
  // "serch" -> "search"; "engins" -> "engine"/"engines". Only the first
  // correctable word is fixed, the rest of the query is preserved verbatim.
  let result = idx.suggest("serch engins")
  assert_eq(result, Some("search engins"))
}

///|
test "suggest skips words that already exist" {
  let idx = suggest_index()
  // "search" is exact; "engins" is correctable -> fix the second word.
  // "engine" and "engines" are both distance 1 (transposition vs insertion);
  // "engines" wins on document frequency (2 docs vs 1).
  assert_eq(idx.suggest("search engins"), Some("search engines"))
}

///|
test "suggest preserves field-scoped terms unchanged" {
  let idx = suggest_index()
  // field:term must not be split or corrected; only bare words are eligible.
  assert_eq(idx.suggest("title:serch"), None)
  assert_eq(idx.suggest("title:serch body:engins"), None)
}

///|
test "suggest corrects bare words around field-scoped terms" {
  let idx = suggest_index()
  // The bare "serch" is corrected; "title:engins" stays untouched.
  assert_eq(idx.suggest("serch title:engins"), Some("search title:engins"))
}

///|
test "suggest preserves quoted phrases and operators" {
  let idx = suggest_index()
  // Phrase content and boolean operators are left verbatim.
  assert_eq(idx.suggest("\"serch engine\""), None)
  assert_eq(idx.suggest("serch AND engins"), Some("search AND engins"))
  assert_eq(idx.suggest("NOT serch"), Some("NOT search"))
}

///|
test "suggest normalizes case like the analyzer" {
  let idx = suggest_index()
  // The analyzer lowercases; "SERCH" should be corrected to "search".
  assert_eq(idx.suggest("SERCH"), Some("search"))
}

///|
test "suggest respects max_distance" {
  let idx = suggest_index()
  // "serch" -> "search" is distance 1, allowed at max_distance=1.
  assert_eq(idx.suggest("serch", max_distance=1), Some("search"))
  // "srch" -> "search" is distance 2; too far at max_distance=1.
  assert_eq(idx.suggest("srch", max_distance=1), None)
  assert_eq(idx.suggest("srch", max_distance=2), Some("search"))
}

///|
test "suggest clamps max_distance to 2" {
  let idx = suggest_index()
  // "serch" -> "research" is distance 3; a huge max_distance must not
  // produce it (hard cap), so the suggestion stays "search".
  assert_eq(idx.suggest("serch", max_distance=99), Some("search"))
}

///|
test "suggest on an empty index returns None" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  assert_eq(idx.suggest("serch"), None)
}

///|
test "suggest preserves surrounding whitespace structure" {
  let idx = suggest_index()
  // Only the correctable token is replaced; spacing is kept as-is.
  assert_eq(idx.suggest("  serch  "), Some("  search  "))
}
