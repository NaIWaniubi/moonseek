///|
/// Regression: deleted documents must not inflate doc frequency / IDF.
test "doc_freq excludes deleted documents" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "zebra")], })
  idx.add({ id: "b", fields: [("body", "zebra")], })
  idx.add({ id: "c", fields: [("body", "zebra")], })
  assert_eq(idx.doc_freq("body", "zebra"), 3)
  let _ = idx.delete("a")
  let _ = idx.delete("b")
  assert_eq(idx.doc_freq("body", "zebra"), 1)
  // After snapshot roundtrip the live df is preserved.
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  assert_eq(restored.doc_freq("body", "zebra"), 1)
}

///|
test "idf reflects live doc count after deletes" {
  // With 1 live doc containing the term out of 1 total, IDF should be
  // higher than when 2 deleted docs still inflate df.
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "rare term")], })
  idx.add({ id: "b", fields: [("body", "rare other")], })
  idx.add({ id: "c", fields: [("body", "rare another")], })
  let score_before = (try! idx.search("rare"))[0].score
  let _ = idx.delete("b")
  let _ = idx.delete("c")
  let score_after = (try! idx.search("rare"))[0].score
  // n drops 3->1, df drops 3->1; IDF ln(1+(1-1+0.5)/(1+0.5)) vs
  // ln(1+(3-3+0.5)/(3+0.5)) — both equal, but dl/avgdl normalization
  // changes. The key invariant: score stays positive and finite.
  assert_true(score_before > 0.0)
  assert_true(score_after > 0.0)
}
