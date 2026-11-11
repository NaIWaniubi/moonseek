///|
/// Numeric document values and aggregations.
///
/// The interesting failures here are silent ones: a histogram that puts -0.5 and
/// +0.5 in the same bucket, an average that treats "no value" as zero, a
/// percentile that ignores its interpolation. Each has a test.

///|
fn agg_index() -> Index {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  // Six documents with numeric `versions` and a `tier` facet.
  let data : Array[(String, Double, String)] = [
    ("a", 1.0, "small"),
    ("b", 3.0, "small"),
    ("c", 5.0, "medium"),
    ("d", 10.0, "medium"),
    ("e", 50.0, "large"),
    ("f", 51.0, "large"),
  ]
  for (id, versions, tier) in data {
    idx.add({ id, fields: [("body", "doc " + id)], })
    let _ = idx.set_num(id, "versions", versions)
    let _ = idx.set_facets(id, [("tier", [tier])])
  }
  // One document with no numeric value at all: it must not drag the average
  // toward zero.
  idx.add({ id: "g", fields: [("body", "doc g")], })
  idx
}

///|
test "numeric values round-trip through the accessors" {
  let idx = agg_index()
  assert_eq(idx.num_of("a", "versions"), Some(1.0))
  assert_eq(idx.num_of("g", "versions"), None)
  assert_eq(idx.num_of("nope", "versions"), None)
  assert_true(idx.numeric_fields().contains("versions"))
}

///|
test "set_num rejects unknown and deleted documents" {
  let idx = agg_index()
  assert_true(!idx.set_num("nope", "versions", 1.0))
  let _ = idx.delete("a")
  assert_true(!idx.set_num("a", "versions", 9.0))
  assert_eq(idx.num_of("a", "versions"), None)
}

///|
test "stats aggregate ignores documents with no value" {
  let idx = agg_index()
  let out = idx.aggregate("*", [StatsAgg("versions")])
  let st = out[0].stats.unwrap()
  // Seven documents in the result set, six of them carrying a value: counting
  // seven with one zero would give avg 20.0 instead of 20.0 over six... the
  // point of the test is that count is 6 and the sum is 120.
  assert_eq(st.count, 6)
  assert_eq(st.sum, 120.0)
  assert_eq(st.min, 1.0)
  assert_eq(st.max, 51.0)
  assert_true((st.avg - 20.0).abs() < 1.0e-9)
}

///|
test "terms aggregation counts facet values and sorts by count" {
  let idx = agg_index()
  let out = idx.aggregate("*", [TermsAgg("tier", 10)])
  let buckets = out[0].buckets
  assert_eq(buckets.length(), 3)
  // All three tiers have two documents; ties break by ascending label.
  assert_eq(buckets[0].0, "large")
  assert_eq(buckets[0].1, 2.0)
  assert_eq(buckets[1].0, "medium")
  assert_eq(buckets[2].0, "small")
}

///|
test "terms aggregation honours its size cap" {
  let idx = agg_index()
  let out = idx.aggregate("*", [TermsAgg("tier", 2)])
  assert_eq(out[0].buckets.length(), 2)
}

///|
test "histogram buckets by interval and labels the lower edge" {
  let idx = agg_index()
  // Interval 10 over 1,3,5,10,50,51 puts 1/3/5 in [0,10), 10 in [10,20),
  // 50/51 in [50,60).
  let out = idx.aggregate("*", [HistogramAgg("versions", 10.0)])
  let buckets = out[0].buckets
  assert_eq(buckets.length(), 3)
  assert_eq(buckets[0].0, "0")
  assert_eq(buckets[0].1, 3.0)
  assert_eq(buckets[1].0, "10")
  assert_eq(buckets[1].1, 1.0)
  assert_eq(buckets[2].0, "50")
  assert_eq(buckets[2].1, 2.0)
}

///|
test "histogram with a non-positive interval returns nothing rather than one infinite bucket" {
  let idx = agg_index()
  let out = idx.aggregate("*", [HistogramAgg("versions", 0.0)])
  assert_eq(out[0].buckets.length(), 0)
  let negative = idx.aggregate("*", [HistogramAgg("versions", -5.0)])
  assert_eq(negative[0].buckets.length(), 0)
}

///|
test "histogram floor division is correct for negative values" {
  // -0.5 and +0.5 must land in different buckets: truncation toward zero would
  // put both in bucket 0.
  assert_eq(floor_div(0.5, 1.0), 0)
  assert_eq(floor_div(-0.5, 1.0), -1)
  assert_eq(floor_div(-1.5, 1.0), -2)
  assert_eq(floor_div(-10.0, 10.0), -1)
}

///|
test "percentiles interpolate rather than snapping to a sample" {
  let idx = agg_index()
  // Sorted values: 1,3,5,10,50,51. The median falls between 5 and 10.
  let out = idx.aggregate("*", [PercentilesAgg("versions", [50.0, 0.0, 100.0])])
  let ps = out[0].percentiles
  assert_true((ps[0].1 - 7.5).abs() < 1.0e-9)
  assert_eq(ps[1].1, 1.0)
  assert_eq(ps[2].1, 51.0)
}

///|
test "aggregations run over the filtered result set" {
  let idx = agg_index()
  // Only the two "small" documents.
  let out = idx.aggregate("*", [StatsAgg("versions"), TermsAgg("tier", 10)], filters=[
    ("tier", ["small"]),
  ])
  let st = out[0].stats.unwrap()
  assert_eq(st.count, 2)
  assert_eq(st.sum, 4.0)
  assert_eq(out[1].buckets.length(), 1)
  assert_eq(out[1].buckets[0].0, "small")
}

///|
test "aggregations follow the query, not the whole index" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "alpha")], })
  idx.add({ id: "b", fields: [("body", "beta")], })
  let _ = idx.set_num("a", "n", 10.0)
  let _ = idx.set_num("b", "n", 100.0)
  let out = idx.aggregate("alpha", [StatsAgg("n")])
  let st = out[0].stats.unwrap()
  // Aggregating over the index rather than the result set would report 110.
  assert_eq(st.sum, 10.0)
  assert_eq(st.count, 1)
}

///|
test "empty result set aggregates to zero rather than failing" {
  let idx = agg_index()
  let out = idx.aggregate("nonexistentterm", [StatsAgg("versions")])
  let st = out[0].stats.unwrap()
  assert_eq(st.count, 0)
  assert_eq(st.sum, 0.0)
}

///|
test "external statistics override local scoring statistics" {
  let idx = aggregate_fixture()
  let before = idx.search("common", limit=0)
  assert_eq(before.length(), 3)
  // Pretend the corpus is far larger and the term far rarer: IDF must go up,
  // and with it every score. This is the mechanism a cluster coordinator uses
  // to make shards agree on a ranking.
  let df : Array[((String, String), Int32)] = [(("body", "common"), 3)]
  let avgdl : Array[(String, Double)] = [("body", 1.0)]
  idx.set_external_stats(Some(ExternalStats::new(100000, df~, avgdl~)))
  let global = idx.search("common", limit=0)
  assert_eq(global.length(), 3)
  assert_true(global[0].score > before[0].score)
  // A term absent from the override map keeps its local df.
  assert_true(idx.has_external_stats())
  idx.set_external_stats(None)
  assert_true(!idx.has_external_stats())
  let restored = idx.search("common", limit=0)
  assert_eq(restored[0].score, before[0].score)
}

///|
fn aggregate_fixture() -> Index {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  for i in 0..<3 {
    idx.add({ id: "d\{i}", fields: [("body", "common")], })
  }
  idx
}

///|
test "scoring terms of a query are the terms the evaluator scores" {
  let idx = Index::new([
    { name: "title", weight: 2.0, },
    { name: "body", weight: 1.0, },
  ])
  let fields : Array[String] = ["title", "body"]
  // A bare term expands to one pair per field.
  let bare = parse_query("alpha", fields~) catch { _ => abort("parse") }
  let pairs = scoring_terms(idx, bare).unwrap()
  assert_eq(pairs.length(), 2)
  // A field-scoped term yields one.
  let scoped = parse_query("title:beta", fields~) catch { _ => abort("parse") }
  assert_eq(scoring_terms(idx, scoped).unwrap().length(), 1)
  // A phrase contributes its first term, matching the evaluator.
  let phrase = parse_query("\"gamma delta\"", fields~) catch {
    _ => abort("parse")
  }
  let phrase_pairs = scoring_terms(idx, phrase).unwrap()
  assert_eq(phrase_pairs.length(), 2)
  assert_eq(phrase_pairs[0].1, "gamma")
  // A prefix is shard-dependent: the coordinator must refuse to guess.
  let prefix = parse_query("gam*", fields~) catch { _ => abort("parse") }
  assert_true(scoring_terms(idx, prefix) is None)
}
