///|
/// Index with terms chosen so that edit-distance bands are unambiguous.
/// Distances from "serch": search=1, searchx=2, research=3, seaside=4.
fn fuzzy_index() -> @moonseek.Index {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  idx.add({
    id: "d1",
    fields: [
      ("title", "search engine"),
      ("body", "search search search engines are useful"),
    ],
  })
  idx.add({
    id: "d2",
    fields: [
      ("title", "research notes"),
      ("body", "all about searchx and indexing"),
    ],
  })
  idx.add({ id: "d3", fields: [("body", "seaside shells")], })
  idx.add({ id: "d4", fields: [("body", "xylophone music")], })
  idx
}

///|
fn fuzzy_hit_ids(hits : Array[@moonseek.Hit]) -> Array[String] {
  hits.map(fn(h) { h.id })
}

///|
fn fuzzy_pairs(matches : Array[@moonseek.FuzzyMatch]) -> Array[(String, Int32)] {
  matches.map(fn(m) { (m.term, m.distance) })
}

///|
test "levenshtein known vectors" {
  assert_eq(@moonseek.levenshtein("kitten", "sitting"), 3)
  assert_eq(@moonseek.levenshtein("flaw", "lawn"), 2)
  assert_eq(@moonseek.levenshtein("saturday", "sunday"), 3)
  assert_eq(@moonseek.levenshtein("book", "back"), 2)
}

///|
test "levenshtein empty and identical" {
  assert_eq(@moonseek.levenshtein("", "abc"), 3)
  assert_eq(@moonseek.levenshtein("abc", ""), 3)
  assert_eq(@moonseek.levenshtein("", ""), 0)
  assert_eq(@moonseek.levenshtein("abc", "abc"), 0)
}

///|
test "levenshtein is symmetric" {
  let words = ["kitten", "sitting", "flaw", "lawn", "search", "serch", ""]
  for a in words {
    for b in words {
      assert_eq(@moonseek.levenshtein(a, b), @moonseek.levenshtein(b, a))
    }
  }
}

///|
test "levenshtein obeys triangle inequality" {
  let words = ["kitten", "sitting", "saturday", "sunday", "search", "serch"]
  for a in words {
    for b in words {
      for c in words {
        assert_true(
          @moonseek.levenshtein(a, c) <=
          @moonseek.levenshtein(a, b) + @moonseek.levenshtein(b, c),
        )
      }
    }
  }
}

///|
test "levenshtein unicode characters" {
  // Single CJK characters are one edit apart, not one byte apart.
  assert_eq(@moonseek.levenshtein("猫", "犬"), 1)
  assert_eq(@moonseek.levenshtein("全文", "全犬"), 1)
  assert_eq(@moonseek.levenshtein("搜索", "搜"), 1)
  assert_eq(@moonseek.levenshtein("", "猫犬"), 2)
  // Astral-plane characters count as one Char each.
  assert_eq(@moonseek.levenshtein("🚀", "🌟"), 1)
}

///|
test "damerau counts adjacent transposition as one edit" {
  assert_eq(@moonseek.damerau_levenshtein("ca", "ac"), 1)
  assert_eq(@moonseek.damerau_levenshtein("ab", "ba"), 1)
  assert_eq(@moonseek.damerau_levenshtein("abc", "acb"), 1)
  // Plain Levenshtein needs two edits for the same transposition.
  assert_eq(@moonseek.levenshtein("ca", "ac"), 2)
}

///|
test "damerau known vectors" {
  assert_eq(@moonseek.damerau_levenshtein("kitten", "sitting"), 3)
  assert_eq(@moonseek.damerau_levenshtein("", "abc"), 3)
  assert_eq(@moonseek.damerau_levenshtein("abc", "abc"), 0)
  assert_eq(@moonseek.damerau_levenshtein("猫犬", "犬猫"), 1)
  // Non-adjacent repetition is not a single transposition.
  assert_eq(@moonseek.damerau_levenshtein("ca", "abc"), 3)
}

///|
test "damerau never exceeds levenshtein" {
  let words = ["kitten", "sitting", "ca", "ac", "abc", "acb", "search", ""]
  for a in words {
    for b in words {
      assert_true(
        @moonseek.damerau_levenshtein(a, b) <= @moonseek.levenshtein(a, b),
      )
    }
  }
}

///|
test "fuzzy_terms filters by distance and sorts by (distance, term)" {
  let idx = fuzzy_index()
  let matches = idx.fuzzy_terms("serch")
  assert_eq(fuzzy_pairs(matches), [("search", 1), ("searchx", 2)])
}

///|
test "fuzzy_terms distance zero is exact match only" {
  let idx = fuzzy_index()
  assert_eq(fuzzy_pairs(idx.fuzzy_terms("search", max_distance=0)), [
    ("search", 0),
  ])
  assert_eq(idx.fuzzy_terms("serch", max_distance=0).length(), 0)
}

///|
test "fuzzy_terms max_distance is clamped to 2" {
  let idx = fuzzy_index()
  // "serch" -> "research" is distance 3; even a huge max_distance must not
  // return it (Lucene-style hard cap).
  let huge = idx.fuzzy_terms("serch", max_distance=99)
  assert_true(!fuzzy_pairs(huge).contains(("research", 3)))
  assert_eq(huge, idx.fuzzy_terms("serch", max_distance=2))
}

///|
test "fuzzy_terms negative max_distance behaves as zero" {
  let idx = fuzzy_index()
  assert_eq(
    idx.fuzzy_terms("search", max_distance=-3),
    idx.fuzzy_terms("search", max_distance=0),
  )
}

///|
test "fuzzy_terms length pruning never drops valid matches" {
  let idx = fuzzy_index()
  // "xylophone" is far longer than any term within distance 2 of "cat".
  assert_eq(idx.fuzzy_terms("cat").length(), 0)
  // But a 2-char term within 2 edits of a 4-char term must still match:
  // "se" -> "search" is distance 4 (excluded), while "sea" -> "seaside" is 4.
  // Use a crafted pair instead: index has "search"; query "sear" (len 4).
  assert_eq(fuzzy_pairs(idx.fuzzy_terms("sear")), [("search", 2)])
}

///|
test "fuzzy_terms field scoping and dedup" {
  let idx = fuzzy_index()
  // "search" lives in title and body of d1; must appear once, not twice.
  let matches = idx.fuzzy_terms("serch")
  assert_eq(matches.length(), 2)
  // "research" only exists in title; scoped to body it disappears.
  let title_only = idx.fuzzy_terms("reserch", field=Some("title"))
  assert_true(fuzzy_pairs(title_only).contains(("research", 1)))
  let body_only = idx.fuzzy_terms("reserch", field=Some("body"))
  assert_eq(body_only.length(), 0)
}

///|
test "fuzzy_terms unknown field and empty index" {
  let idx = fuzzy_index()
  assert_eq(idx.fuzzy_terms("serch", field=Some("nonexistent")).length(), 0)
  let empty = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  assert_eq(empty.fuzzy_terms("serch").length(), 0)
}

///|
test "fuzzy_search finds documents for a misspelled term" {
  let idx = fuzzy_index()
  let hits = idx.fuzzy_search("serch")
  assert_true(hits.length() >= 1)
  assert_eq(hits[0].id, "d1")
  // d2 contains "searchx" (distance 2 from "serch").
  assert_true(fuzzy_hit_ids(hits).contains("d2"))
}

///|
test "fuzzy_search exact term matches normal search scores" {
  let idx = fuzzy_index()
  let fuzzy = idx.fuzzy_search("search", max_distance=0)
  let exact = idx.search("search")
  assert_eq(fuzzy.length(), exact.length())
  for i in 0..<fuzzy.length() {
    assert_eq(fuzzy[i].id, exact[i].id)
    assert_eq(fuzzy[i].score, exact[i].score)
  }
}

///|
test "fuzzy_search merges variant scores by taking the max" {
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  // "both" contains "search" (distance 1 from "serch") and "searchx"
  // (distance 2). With one token each and df=1 for both terms, "searchx"
  // has the longer field length, hence the lower BM25 score: the merged
  // score must equal the better variant's exact-search score, not the sum.
  idx.add({ id: "both", fields: [("body", "search searchx")], })
  idx.add({ id: "rare", fields: [("body", "searchx")], })
  let hits = idx.fuzzy_search("serch", limit=0)
  assert_eq(hits.length(), 2)
  let exact = idx.search("search", limit=0)
  let both_exact : Array[@moonseek.Hit] = exact.filter(fn(h : @moonseek.Hit) {
    h.id == "both"
  })
  let both_fuzzy : Array[@moonseek.Hit] = hits.filter(fn(h : @moonseek.Hit) {
    h.id == "both"
  })
  assert_eq(both_fuzzy[0].score, both_exact[0].score)
  // And it must be strictly less than the sum of the two variant scores.
  let variant = idx.search("searchx", limit=0)
  let both_variant : Array[@moonseek.Hit] = variant.filter(fn(
    h : @moonseek.Hit,
  ) {
    h.id == "both"
  })
  assert_true(both_fuzzy[0].score < both_exact[0].score + both_variant[0].score)
}

///|
test "fuzzy_search sorts by score then id and respects limit" {
  let idx = fuzzy_index()
  let all = idx.fuzzy_search("serch", limit=0)
  let capped = idx.fuzzy_search("serch", limit=1)
  assert_eq(capped.length(), 1)
  assert_eq(capped[0], all[0])
  // Sorted descending by score, ties by id.
  for i in 1..<all.length() {
    assert_true(
      all[i - 1].score > all[i].score ||
      (all[i - 1].score == all[i].score && all[i - 1].id <= all[i].id),
    )
  }
}

///|
test "fuzzy_search excludes deleted documents" {
  let idx = fuzzy_index()
  assert_true(idx.delete("d1"))
  let hits = idx.fuzzy_search("serch")
  assert_true(!fuzzy_hit_ids(hits).contains("d1"))
}

///|
test "fuzzy_search no candidates returns empty" {
  let idx = fuzzy_index()
  assert_eq(idx.fuzzy_search("zzzzzzzzzzzz").length(), 0)
}
