///|
/// Sloppy phrase queries: `"a b"~N` matches when each term appears in order
/// and no gap between neighbours exceeds N tokens.
///
/// The tests below pin the three things this feature can get wrong:
///   1. slop 0 must be *identical* to the pre-existing exact-phrase behaviour;
///   2. a larger slop must be a superset (monotone in N);
///   3. the phrase frequency must count occurrences, not starting positions —
///      the naive implementation inflates tf and therefore the BM25 score.

///|
fn slop_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0 }])
  // "alpha beta" adjacent (slop 0), then a 1-token gap, then a 2-token gap,
  // then reversed order (must never match an ordered phrase).
  idx.add({ id: "adjacent", fields: [("body", "alpha beta gamma delta")] })
  idx.add({ id: "gap1", fields: [("body", "alpha x beta gamma")] })
  idx.add({ id: "gap2", fields: [("body", "alpha x y beta gamma")] })
  idx.add({ id: "reversed", fields: [("body", "beta alpha gamma")] })
  idx.add({ id: "far", fields: [("body", "alpha x y z w beta")] })
  idx
}

///|
fn slop_ids(
  idx : @moonseek.Index,
  query : String,
) -> Array[String] raise @moonseek.QueryError {
  let ids = (idx.search(query, limit=0)).map(fn(h) { h.id })
  // lexicographic, so expectations read alphabetically (sort() is shortlex)
  ids.sort_by(fn(a, b) { a.lexical_compare(b) })
  ids
}

///|
test "slop 0 is exactly the old exact-phrase behaviour" {
  let idx = slop_index()
  // No slop suffix and explicit ~0 must agree.
  assert_eq(slop_ids(idx, "\"alpha beta\""), ["adjacent"])
  assert_eq(slop_ids(idx, "\"alpha beta\"~0"), ["adjacent"])
}

///|
test "slop admits ordered matches within the gap budget" {
  let idx = slop_index()
  // 1 token between -> needs slop 1.
  assert_eq(slop_ids(idx, "\"alpha beta\"~1"), ["adjacent", "gap1"])
  // 2 tokens between -> slop 2; "far" has 4 and stays out.
  assert_eq(slop_ids(idx, "\"alpha beta\"~2"), ["adjacent", "gap1", "gap2"])
  assert_eq(slop_ids(idx, "\"alpha beta\"~4"), ["adjacent", "far", "gap1", "gap2"])
}

///|
test "slop never matches reversed order" {
  let idx = slop_index()
  // "reversed" has beta before alpha; no amount of slop may admit it, because
  // slop widens gaps but does not reorder terms.
  for n in [0, 1, 2, 3, 5, 50] {
    let ids = slop_ids(idx, "\"alpha beta\"~\{n}")
    assert_true(!ids.contains("reversed"))
  }
}

///|
test "slop is monotone: a larger budget is a superset" {
  let idx = slop_index()
  let mut prev : Array[String] = []
  for n in 0..<7 {
    let cur = slop_ids(idx, "\"alpha beta\"~\{n}")
    for id in prev {
      assert_true(cur.contains(id))
    }
    prev = cur
  }
}

///|
test "phrase frequency counts occurrences, not starting positions" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0 }])
  // "alpha x beta" appears three times. With slop 1 a naive implementation
  // would also count each of the three positions of "alpha" against each of
  // the three of "beta" that lie in range, giving 9 instead of 3.
  idx.add({
    id: "three",
    fields: [("body", "alpha x beta alpha x beta alpha x beta")],
  })
  idx.add({ id: "once", fields: [("body", "alpha x beta")] })
  let exp = idx.explain("\"alpha beta\"~1", "three")
  let detail = match exp {
    Some(e) =>
      match e.details[0] {
        d => d.tf
      }
    None => -1
  }
  assert_eq(detail, 3)
  // And the document with three occurrences must outrank the one with one.
  let hits = idx.search("\"alpha beta\"~1", limit=0)
  assert_eq(hits[0].id, "three")
}

///|
test "slop works with three or more terms" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0 }])
  idx.add({ id: "tight", fields: [("body", "a b c")] })
  idx.add({ id: "loose", fields: [("body", "a x b y c")] })
  idx.add({ id: "too-loose", fields: [("body", "a x y b z w c")] })
  // Each of the two gaps costs 1 token in "loose", so slop 1 admits it.
  assert_eq(slop_ids(idx, "\"a b c\""), ["tight"])
  assert_eq(slop_ids(idx, "\"a b c\"~1"), ["loose", "tight"])
  // "too-loose" needs 2 tokens in each gap: slop 2 admits it, slop 1 does not.
  assert_eq(slop_ids(idx, "\"a b c\"~2"), ["loose", "tight", "too-loose"])
}

///|
test "slop is scoped by the field prefix" {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 2.0 },
    { name: "body", weight: 1.0 },
  ])
  idx.add({
    id: "a",
    fields: [("title", "alpha beta"), ("body", "alpha x y beta")],
  })
  // title has them adjacent -> matches even at slop 0.
  assert_eq(slop_ids(idx, "title:\"alpha beta\""), ["a"])
  // body needs 2 -> not at slop 0, yes at slop 2.
  assert_eq(slop_ids(idx, "body:\"alpha beta\""), [])
  assert_eq(slop_ids(idx, "body:\"alpha beta\"~2"), ["a"])
}

///|
test "slop survives a boolean combination" {
  let idx = slop_index()
  // A sloppy phrase is a normal set operand.
  assert_eq(
    slop_ids(idx, "\"alpha beta\"~2 AND gamma"),
    ["adjacent", "gap1", "gap2"],
  )
  // NOT with a sloppy phrase excludes exactly its matches.
  let all = slop_ids(idx, "*")
  let outside = slop_ids(idx, "\"alpha beta\"~1")
  let expected : Array[String] = []
  for id in all {
    if !outside.contains(id) {
      expected.push(id)
    }
  }
  assert_eq(slop_ids(idx, "* NOT \"alpha beta\"~1"), expected)
}

///|
test "slop round-trips through a snapshot" {
  let idx = slop_index()
  let restored = @moonseek.Index::from_bytes(idx.to_bytes())
  let before = slop_ids(idx, "\"alpha beta\"~2")
  let after = slop_ids(restored, "\"alpha beta\"~2")
  assert_eq(before, after)
}

///|
test "CJK slop: distance between two CJK runs is gap-tolerant" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0 }])
  // Overlapping bigrams are what make "搜索引擎" a three-token exact phrase:
  // 全文0 文搜1 搜索2 索引3 引擎4. Note that inserting a character *breaks
  // the bigram chain itself* (索的 is a different term than 索引), so the
  // interesting slop case for CJK is the distance between two separate runs.
  idx.add({ id: "compound", fields: [("body", "全文搜索引擎")] })
  idx.add({ id: "one-gap", fields: [("body", "搜索 qq 引擎")] })
  idx.add({ id: "two-gaps", fields: [("body", "搜索 qq zz 引擎")] })
  // In "compound" 搜索(2) and 引擎(4) are one token apart, so slop 1 covers it.
  assert_eq(slop_ids(idx, "\"搜索 引擎\"~1"), ["compound", "one-gap"])
  assert_eq(slop_ids(idx, "\"搜索 引擎\"~2"), [
    "compound",
    "one-gap",
    "two-gaps",
  ])
  // Exact adjacency of two separate runs still works at slop 0.
  idx.add({ id: "tight", fields: [("body", "搜索 引擎")] })
  assert_eq(slop_ids(idx, "\"搜索 引擎\""), ["tight"])
}