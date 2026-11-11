///|
fn explain_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "a",
    fields: [("title", "moonbit language"), ("body", "moonbit wasm fast")],
  })
  idx.add({
    id: "b",
    fields: [("title", "rust language"), ("body", "rust systems safe")],
  })
  idx.add({
    id: "c",
    fields: [("title", "go language"), ("body", "go cloud simple")],
  })
  idx
}

///|
test "explain: returns details for matching doc" {
  let idx = explain_index()
  let exp = idx.explain("moonbit", "a")
  assert_true(exp is Some(_))
  match exp {
    Some(e) => {
      assert_eq(e.id, "a")
      assert_true(e.total_score > 0.0)
      assert_true(e.details.length() > 0)
      // Should have contributions from title and body
      let fields = e.details.map(fn(d) { d.field })
      assert_true(fields.contains("title"))
      assert_true(fields.contains("body"))
    }
    None => fail("should match")
  }
}

///|
test "explain: non-matching doc returns None" {
  let idx = explain_index()
  assert_eq(idx.explain("moonbit", "b"), None)
}

///|
test "explain: unknown doc returns None" {
  let idx = explain_index()
  assert_eq(idx.explain("moonbit", "nonexistent"), None)
}

///|
test "explain: detail scores sum close to total" {
  let idx = explain_index()
  match idx.explain("language", "a") {
    Some(e) => {
      let mut sum = 0.0
      for d in e.details {
        sum += d.score
      }
      // For a single-term query, details should sum to total
      assert_true((sum - e.total_score).abs() < 0.0001)
    }
    None => fail("should match")
  }
}

///|
test "sort: ScoreAsc reverses order" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "rare")], })
  idx.add({ id: "b", fields: [("body", "rare rare rare")], })
  idx.add({ id: "c", fields: [("body", "rare rare")], })
  let desc = idx.search_sorted("rare", sort=@moonseek.SortOrder::ScoreDesc)
  let asc = idx.search_sorted("rare", sort=@moonseek.SortOrder::ScoreAsc)
  assert_eq(desc.length(), asc.length())
  // Highest score first in desc, lowest first in asc
  assert_true(desc[0].score >= desc[desc.length() - 1].score)
  assert_true(asc[0].score <= asc[asc.length() - 1].score)
  assert_eq(desc[0].id, asc[asc.length() - 1].id)
}

///|
test "sort: IdAsc sorts by id" {
  let idx = explain_index()
  let hits = idx.search_sorted(
    "language",
    sort=@moonseek.SortOrder::IdAsc,
    limit=0,
  )
  assert_eq(hits[0].id, "a")
  assert_eq(hits[1].id, "b")
  assert_eq(hits[2].id, "c")
}

///|
test "sort: IdDesc reverses id order" {
  let idx = explain_index()
  let hits = idx.search_sorted(
    "language",
    sort=@moonseek.SortOrder::IdDesc,
    limit=0,
  )
  assert_eq(hits[0].id, "c")
  assert_eq(hits[2].id, "a")
}

///|
test "search_after: cursor pagination" {
  let idx = explain_index()
  let page1 = idx.search("language", limit=2)
  assert_eq(page1.length(), 2)
  let last = page1[page1.length() - 1]
  let page2 = idx.search_after(
    "language",
    after_score=last.score,
    after_id=last.id,
    limit=2,
  )
  assert_eq(page2.length(), 1)
  // No overlap between pages
  assert_true(page2[0].id != page1[0].id)
  assert_true(page2[0].id != page1[1].id)
}

///|
test "search_after: beyond last returns empty" {
  let idx = explain_index()
  let all = idx.search("language", limit=0)
  let last = all[all.length() - 1]
  let page = idx.search_after(
    "language",
    after_score=last.score,
    after_id=last.id,
  )
  assert_eq(page.length(), 0)
}

///|
test "search_after: full traversal covers all docs" {
  let idx = explain_index()
  let collected : Array[String] = []
  let mut score = 1.0e308
  let mut id = ""
  while true {
    let page = idx.search_after(
      "language",
      after_score=score,
      after_id=id,
      limit=1,
    )
    if page.is_empty() {
      break
    }
    collected.push(page[0].id)
    score = page[0].score
    id = page[0].id
  }
  assert_eq(collected.length(), 3)
}

///|
/// Numeric sort orders.
///
/// The case worth a test is the document with no value for the field: treating
/// it as zero would make "sort by year descending" file every undated document
/// between the oldest and the newest, which looks like data rather than a bug.
///
/// Note the helper: the package already has an `ids_of` that **sorts** its
/// result, for order-insensitive set comparisons. Reusing it here would hide
/// the very thing these tests are about, which is why this one keeps the order
/// it was given.

///|
fn ordered_ids(hits : Array[@moonseek.Hit]) -> Array[String] {
  let out : Array[String] = []
  for h in hits {
    out.push(h.id)
  }
  out
}

///|
fn numeric_sort_fixture() -> @moonseek.Index {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  let data : Array[(String, Double)] = [("a", 5.0), ("b", 1.0), ("c", 9.0)]
  for (id, year) in data {
    idx.add({ id, fields: [("body", "hit")], })
    let _ = idx.set_num(id, "year", year)
  }
  // No value for `year` at all.
  idx.add({ id: "d", fields: [("body", "hit")], })
  idx
}

///|
test "numeric sort orders by value with the value-less documents last" {
  let idx = numeric_sort_fixture()
  let desc = ordered_ids(
    idx.search_sorted("hit", limit=0, sort=@moonseek.SortOrder::NumDesc("year")),
  )
  assert_eq(desc, ["c", "a", "b", "d"])
  let asc = ordered_ids(
    idx.search_sorted("hit", limit=0, sort=@moonseek.SortOrder::NumAsc("year")),
  )
  assert_eq(asc, ["b", "a", "c", "d"])
  // The value-less document is last in both directions, so it cannot be the
  // result of treating "no value" as zero.
  assert_eq(desc[desc.length() - 1], "d")
  assert_eq(asc[asc.length() - 1], "d")
  // A field nothing declares orders entirely by the id tie-break rather than
  // failing: "sort by a field with no values" is a valid, if useless, request.
  assert_eq(
    ordered_ids(
      idx.search_sorted(
        "hit",
        limit=0,
        sort=@moonseek.SortOrder::NumAsc("nope"),
      ),
    ),
    ["a", "b", "c", "d"],
  )
}

///|
test "numeric sort ties break by id in both directions" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  for id in ["b", "a", "c"] {
    idx.add({ id, fields: [("body", "hit")], })
    let _ = idx.set_num(id, "n", 7.0)
  }
  // The id tie-break is ascending even under a descending numeric order: a
  // stable, documented order rather than whatever the sort happened to do.
  assert_eq(
    ordered_ids(
      idx.search_sorted("hit", limit=0, sort=@moonseek.SortOrder::NumAsc("n")),
    ),
    ["a", "b", "c"],
  )
  assert_eq(
    ordered_ids(
      idx.search_sorted("hit", limit=0, sort=@moonseek.SortOrder::NumDesc("n")),
    ),
    ["a", "b", "c"],
  )
}

///|
test "compare_numeric is antisymmetric and puts missing last both ways" {
  let idx = numeric_sort_fixture()
  for forward in [true, false] {
    // a=5, b=1: the sign flips with the direction...
    let ab = @moonseek.compare_numeric(idx, "year", "a", "b", forward~)
    let ba = @moonseek.compare_numeric(idx, "year", "b", "a", forward~)
    assert_eq(ab, -ba)
    assert_true(ab != 0)
    // ...but "d has no value" does not: missing is last in both directions.
    assert_true(@moonseek.compare_numeric(idx, "year", "a", "d", forward~) < 0)
    assert_true(@moonseek.compare_numeric(idx, "year", "d", "a", forward~) > 0)
  }
  // A document compared with itself is always equal.
  assert_true(
    @moonseek.compare_numeric(idx, "year", "a", "a", forward=true) == 0,
  )
}
