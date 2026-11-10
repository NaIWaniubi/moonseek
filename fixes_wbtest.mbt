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
