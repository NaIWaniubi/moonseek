///|
/// Whitebox regression tests for internal invariants fixed in this round:
/// avgdl denominator semantics (field-scoped live count) and the private
/// MatchField eval branch.

///|
test "avg_field_length denominator excludes field-less documents" {
  let idx = Index::new([
    { name: "title", weight: 1.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({ id: "a1", fields: [("body", "term x")], })
  idx.add({ id: "a2", fields: [("body", "term y")], })
  // Two docs, two tokens each: avgdl(body) = 2.0.
  assert_true((idx.avg_field_length("body") - 2.0).abs() < 0.000000001)
  assert_eq(idx.field_live_count("body"), 2)
  // A declared field with no content anywhere: avgdl 0, live count 0.
  assert_eq(idx.avg_field_length("title"), 0.0)
  assert_eq(idx.field_live_count("title"), 0)
  // Adding a document that declares nothing for body must NOT dilute
  // the body avgdl (the bug: denominator used global doc_count).
  idx.add({ id: "no-body", fields: [("title", "unrelated")], })
  assert_true((idx.avg_field_length("body") - 2.0).abs() < 0.000000001)
  assert_eq(idx.field_live_count("body"), 2)
  assert_eq(idx.field_live_count("title"), 1)
  // Deletion restores the pre-delete denominator.
  let _ = idx.delete("a2")
  assert_true((idx.avg_field_length("body") - 2.0).abs() < 0.000000001)
  assert_eq(idx.field_live_count("body"), 1)
}

///|
test "matchfield eval only returns documents with field content" {
  let idx = Index::new([
    { name: "title", weight: 1.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "withtitle",
    fields: [("title", "moonbit language"), ("body", "rust systems")],
  })
  idx.add({ id: "notitle", fields: [("body", "moonbit runtime")], })
  let hits = idx.search("title:*", limit=0)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].id, "withtitle")
  // NOT with a MatchField left side is also pure exclusion.
  let excluded = idx.search("title:* NOT moonbit", limit=0)
  assert_eq(excluded.length(), 0)
  idx.add({ id: "other", fields: [("title", "go cloud")], })
  let excluded = idx.search("title:* NOT moonbit", limit=0)
  assert_eq(excluded.length(), 1)
  assert_eq(excluded[0].id, "other")
  assert_true(excluded[0].score.abs() < 0.000000001)
}

///|
/// Tombstones must not change query cost. `field_live_count` is called once per
/// (field, term) per query; when it re-scanned the length table on every call,
/// deleting documents made each query O(N) and a selective term went from
/// microseconds to a hundred milliseconds at 200k documents.
test "deletion does not change the field live count's cost or value" {
  let idx = Index::new([
    { name: "title", weight: 2.0, },
    { name: "body", weight: 1.0, },
  ])
  for i in 0..<50 {
    idx.add({
      id: "d\{i}",
      fields: [("title", "t\{i}"), ("body", "common word \{i}")],
    })
  }
  // No tombstones: 50 live documents carrying both fields.
  assert_eq(idx.field_live_count("body"), 50)
  assert_eq(idx.field_live_count("title"), 50)
  // Delete ten and the count drops by ten, exactly.
  for i in 0..<10 {
    let _ = idx.delete("d\{i}")
  }
  assert_eq(idx.field_live_count("body"), 40)
  assert_eq(idx.field_live_count("title"), 40)
  // Deleting a document that declared only one field must not shift the other
  // field's count.
  idx.add({ id: "title-only", fields: [("title", "solo")], })
  assert_eq(idx.field_live_count("body"), 40)
  assert_eq(idx.field_live_count("title"), 41)
  let _ = idx.delete("title-only")
  assert_eq(idx.field_live_count("body"), 40)
  assert_eq(idx.field_live_count("title"), 40)
  // A field nothing carries is zero, not an error.
  assert_eq(idx.field_live_count("nope"), 0)
}
