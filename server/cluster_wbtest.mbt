///|
/// Cluster plumbing: shard assignment, the wire framing, and the statistics
/// clause a coordinator attaches to a two-phase query.
///
/// These are the parts where a mistake is silent rather than loud: shard
/// assignment that changes between runs duplicates documents, and a framing bug
/// corrupts every reply at once.

///|
test "shard assignment is deterministic and in range" {
  let ids = ["a", "pkg/one", "moonbitlang/async", "x", "长名称/包", "z9"]
  for id in ids {
    let first = shard_for(id, 3)
    // Same id, same shard, every time: otherwise a re-index leaves two copies
    // on different shards and a search returns the document twice.
    assert_eq(shard_for(id, 3), first)
    assert_true(first >= 0 && first < 3)
  }
}

///|
test "shard assignment spreads a realistic key set" {
  // Not a distribution test — just a guard that the hash is not degenerate
  // (e.g. returning 0 for everything, which would make the cluster a
  // single node with extra steps).
  let counts = Array::make(3, 0)
  for i in 0..<300 {
    let bucket = shard_for("pkg/\{i}", 3)
    counts[bucket] = counts[bucket] + 1
  }
  for c in counts {
    assert_true(c > 50)
  }
}

///|
test "shard assignment handles degenerate shard counts" {
  assert_eq(shard_for("anything", 0), 0)
  assert_eq(shard_for("anything", 1), 0)
  assert_eq(shard_for("", 3), shard_for("", 3))
}

///|
test "framing round-trips through the length prefix" {
  let payloads : Array[String] = [
    "", "{}", "{\"op\":\"search\",\"query\":\"parser\"}",
    // A multi-byte payload must be measured in bytes, not characters.
     "{\"query\":\"搜索引擎\"}",
  ]
  for text in payloads {
    let bytes = @utf8.encode(text)
    let framed = frame(bytes)
    assert_eq(framed.length(), bytes.length() + 4)
    let header = framed.get_view(end=4).unwrap()
    assert_eq(unframe_length(header), bytes.length())
    let body = framed.get_view(start=4).unwrap()
    assert_eq(@utf8.decode(body) catch { _ => "" }, text)
  }
}

///|
test "frame length is a byte count, not a character count" {
  // "搜" is three UTF-8 bytes and one character. Framing by character count
  // would truncate every non-ASCII payload.
  let text = "搜"
  let framed = frame(@utf8.encode(text))
  assert_eq(unframe_length(framed.get_view(end=4).unwrap()), 3)
}

///|
test "shard lists parse with and without replicas" {
  let plain = parse_shards("127.0.0.1:7901,127.0.0.1:7902")
  assert_eq(plain.length(), 2)
  assert_eq(plain[0].primary, "127.0.0.1:7901")
  assert_eq(plain[0].replicas.length(), 0)
  let replicated = parse_shards("a:1|b:2|c:3,a:4")
  assert_eq(replicated.length(), 2)
  assert_eq(replicated[0].primary, "a:1")
  assert_eq(replicated[0].replicas.length(), 2)
  assert_eq(replicated[0].replicas[0], "b:2")
  assert_eq(replicated[0].replicas[1], "c:3")
  assert_eq(replicated[1].primary, "a:4")
}

///|
test "shard list parsing tolerates whitespace and stray separators" {
  let parsed = parse_shards(" a:1 , b:2 ,, ")
  assert_eq(parsed.length(), 2)
  assert_eq(parsed[0].primary, "a:1")
  assert_eq(parsed[1].primary, "b:2")
  assert_eq(parse_shards("").length(), 0)
  assert_eq(parse_shards(",,").length(), 0)
}

///|
test "stat keys round-trip through the NUL separator" {
  let key = stat_key("title", "parser")
  let (field, term) = split_stat_key(key)
  assert_eq(field, "title")
  assert_eq(term, "parser")
  // A term containing the separator's printable neighbours must not confuse it.
  let tricky = stat_key("desc", "a:b,c")
  let (f2, t2) = split_stat_key(tricky)
  assert_eq(f2, "desc")
  assert_eq(t2, "a:b,c")
}

///|
test "stats clause is empty without statistics and valid JSON with them" {
  assert_eq(stats_clause(None), "")
  let stats = @moonseek.ExternalStats::new(
    3000,
    df=[(("title", "parser"), 146)],
    avgdl=[("title", 2.2)],
  )
  let clause = stats_clause(Some(stats))
  assert_true(clause.has_prefix(",\"stats\":"))
  // The clause is appended inside a larger JSON object, so it has to parse when
  // wrapped. A malformed clause here would make every shard answer "bad json"
  // while the coordinator reported success.
  let wrapped = "{\"op\":\"search\"" + clause + "}"
  let parsed = @json.parse(wrapped) catch {
    _ => abort("stats clause is not valid JSON")
  }
  match parsed {
    Object(fields) =>
      match fields.get("stats") {
        Some(Object(inner)) =>
          match inner.get("n") {
            Some(Number(n, ..)) => assert_eq(n.to_int(), 3000)
            _ => abort("missing n")
          }
        _ => abort("missing stats object")
      }
    _ => abort("not an object")
  }
}

///|
test "a search request carrying statistics is valid JSON" {
  let stats = @moonseek.ExternalStats::new(100, df=[(("body", "x"), 1)], avgdl=[
    ("body", 5.0),
  ])
  let request = "{\"op\":\"search\",\"query\":" +
    @json.to_json("x").stringify() +
    ",\"limit\":10" +
    stats_clause(Some(stats)) +
    "}"
  let reparsed = @json.parse(request) catch {
    _ => abort("request is not JSON")
  }
  match reparsed {
    Object(fields) =>
      match fields.get("query") {
        Some(String(q)) => assert_eq(q, "x")
        _ => abort("missing query")
      }
    _ => abort("not an object")
  }
}

///|
test "coordinator refuses to gather statistics for a prefix query" {
  // A prefix expands against whatever dictionary the shard happens to hold, so
  // two shards would gather different term sets and neither ranking would be
  // right. Returning None lets the caller say so instead of mixing rankings.
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "parser")], })
  assert_true(query_terms(idx, "parser") is Some(_))
  assert_true(query_terms(idx, "par*") is None)
  // An unparseable query is also None rather than an error.
  assert_true(query_terms(idx, "\"unterminated") is None)
}

///|
/// The hash is pinned against the JavaScript implementation in
/// `tools/shard-hash-vector.mjs`.
///
/// These numbers are not derived from anything in this file — they were
/// produced by running that script with Node and pasted here. If the MoonBit
/// hash drifts, this test fails and the offline splitter is known to disagree
/// with the coordinator. That matters because the two must place a document on
/// the same shard, or the coordinator would route a write to a shard that the
/// splitter never put the document on. They also cover a CJK id, which the old
/// UTF-16-based hash got wrong (it agreed for ASCII only by accident).
test "hash matches the reference implementation byte for byte" {
  // (id, fnv1a, hash_key)
  let vectors : Array[(String, UInt32, UInt32)] = [
    ("a", 3826002220U, 444641715U),
    ("pkg/one", 3941560482U, 3765489145U),
    ("moonbitlang/async", 2893386792U, 1277040534U),
    ("web/pkg0", 1241992696U, 2333536307U),
    ("cli/pkg1", 2141518003U, 2099387623U),
    ("搜索引擎/包", 4208254012U, 3745089171U),
    ("中文分词器", 3428860724U, 917390383U),
    ("z9", 342331900U, 3797109931U),
  ]
  for (id, raw, mixed) in vectors {
    assert_eq(fnv1a(id), raw)
    assert_eq(hash_key(id), mixed)
  }
}

///|
test "ring placement matches the reference implementation" {
  // (id, ring(3), ring(4)) — same source as the vectors above.
  let vectors : Array[(String, Int32, Int32)] = [
    ("a", 0, 0),
    ("pkg/one", 2, 2),
    ("moonbitlang/async", 1, 1),
    ("web/pkg0", 1, 1),
    ("cli/pkg1", 0, 0),
    ("搜索引擎/包", 0, 0),
    ("中文分词器", 2, 3),
    ("z9", 0, 0),
  ]
  let three = build_ring(3)
  let four = build_ring(4)
  assert_eq(three.points.length(), 3 * RING_VNODES)
  for (id, on_three, on_four) in vectors {
    assert_eq(three.owner(id), on_three)
    assert_eq(four.owner(id), on_four)
  }
}

///|
test "adding a shard moves a quarter of the keys, not all of them" {
  let ids : Array[String] = []
  for i in 0..<20000 {
    ids.push("pkg/\{i}")
  }
  let ring = rebalance_plan(ids, 3, 4, Ring)
  let modulo = rebalance_plan(ids, 3, 4, Modulo)
  // The ideal for 3 -> 4 is 1/4 of the keys, because the new shard takes a
  // quarter of the ring. The ring lands near it; modulo, which changes the
  // divisor for every key, moves about three quarters.
  let ring_pct = ring.moved.to_double() / ring.total.to_double()
  let modulo_pct = modulo.moved.to_double() / modulo.total.to_double()
  assert_true(ring_pct > 0.20 && ring_pct < 0.30)
  assert_true(modulo_pct > 0.65 && modulo_pct < 0.85)
  // And the ring is even: every shard gets within 20% of its share of the keys.
  for count in ring.after {
    let share = count.to_double() / ring.total.to_double()
    assert_true(share > 0.20 && share < 0.30)
  }
}

///|
test "the ring is stable when the shard count does not change" {
  let ids : Array[String] = []
  for i in 0..<2000 {
    ids.push("pkg/\{i}")
  }
  let same = rebalance_plan(ids, 3, 3, Ring)
  assert_eq(same.moved, 0)
  // A shard's address is not part of the key, so rebuilding the ring cannot
  // move anything: only adding or removing a shard may.
  assert_eq(build_ring(3).owner("pkg/1"), build_ring(3).owner("pkg/1"))
}

///|
test "Ring::owner is in range for every key and never panics on an empty ring" {
  let empty = build_ring(0)
  assert_eq(empty.points.length(), 0)
  assert_eq(empty.owner("anything"), 0)
  let ring = build_ring(5)
  for i in 0..<500 {
    let owner = ring.owner("key/\{i}")
    assert_true(owner >= 0 && owner < 5)
  }
}

///|
test "shard modes parse and reject typos" {
  assert_true(parse_shard_mode("ring") is Some(Ring))
  assert_true(parse_shard_mode("") is Some(Ring))
  assert_true(parse_shard_mode("MODULO") is Some(Modulo))
  // An unknown word must not silently fall back: a coordinator using a
  // different rule than the operator asked for places documents where the
  // operator's own tooling disagrees.
  assert_true(parse_shard_mode("ring2") is None)
}

///|
/// Per-shard aggregations merged into a corpus-wide answer.
///
/// Every case here is a merge rule that is easy to get subtly wrong and that
/// produces a plausible number when you do, which is the worst combination.

///|
fn agg_terms(
  field : String,
  buckets : Array[(String, Double)],
) -> @moonseek.AggResult {
  let out : @moonseek.AggResult = {
    field,
    kind: "terms",
    buckets,
    stats: None,
    percentiles: [],
  }
  out
}

///|
fn agg_stats(field : String, st : @moonseek.StatSummary) -> @moonseek.AggResult {
  let out : @moonseek.AggResult = {
    field,
    kind: "stats",
    buckets: [],
    stats: Some(st),
    percentiles: [],
  }
  out
}

///|
fn agg_histogram(
  field : String,
  buckets : Array[(String, Double)],
) -> @moonseek.AggResult {
  let out : @moonseek.AggResult = {
    field,
    kind: "histogram",
    buckets,
    stats: None,
    percentiles: [],
  }
  out
}

///|
fn agg_percentiles(
  field : String,
  ps : Array[(Double, Double)],
) -> @moonseek.AggResult {
  let out : @moonseek.AggResult = {
    field,
    kind: "percentiles",
    buckets: [],
    stats: None,
    percentiles: ps,
  }
  out
}

///|
test "terms merge sums counts across shards and caps after merging" {
  let replies : Array[AggReply] = [
    {
      results: [agg_terms("license", [("MIT", 3.0), ("Apache-2.0", 1.0)])],
      values: [],
    },
    {
      results: [agg_terms("license", [("MIT", 2.0), ("GPL", 4.0)])],
      values: [],
    },
  ]
  let merged = merge_aggregates([@moonseek.TermsAgg("license", 0)], replies)
  assert_eq(merged.length(), 1)
  let buckets = merged[0].buckets
  assert_eq(buckets.length(), 3)
  // Counts are corpus-wide: MIT is 3 + 2, not 3 or 2.
  assert_eq(buckets[0], ("MIT", 5.0))
  assert_eq(buckets[1], ("GPL", 4.0))
  assert_eq(buckets[2], ("Apache-2.0", 1.0))
  // A GPL that is rank 1 inside one shard must survive a global cap of 2. If
  // each shard had applied the cap itself, only MIT and Apache would have come
  // back from shard 1 and GPL would have been dropped entirely.
  let capped = merge_aggregates([@moonseek.TermsAgg("license", 2)], replies)
  assert_eq(capped[0].buckets.length(), 2)
  assert_eq(capped[0].buckets[1], ("GPL", 4.0))
}

///|
test "stats merge recombines counts instead of averaging the averages" {
  let small : @moonseek.StatSummary = {
    count: 2,
    min: 1.0,
    max: 3.0,
    avg: 2.0,
    sum: 4.0,
  }
  let large : @moonseek.StatSummary = {
    count: 40,
    min: 10.0,
    max: 50.0,
    avg: 30.0,
    sum: 1200.0,
  }
  let replies : Array[AggReply] = [
    { results: [agg_stats("versions", small)], values: [], },
    { results: [agg_stats("versions", large)], values: [], },
  ]
  let merged = merge_aggregates([@moonseek.StatsAgg("versions")], replies)
  let st = merged[0].stats.unwrap()
  assert_eq(st.count, 42)
  assert_eq(st.min, 1.0)
  assert_eq(st.max, 50.0)
  assert_eq(st.sum, 1204.0)
  // The mean of the union is 1204/42 = 28.67. Averaging the two averages gives
  // 16.0 — a wrong answer that looks entirely reasonable in a dashboard, which
  // is why it is worth a test rather than a comment.
  assert_true((st.avg - 1204.0 / 42.0).abs() < 1.0e-9)
  assert_true((st.avg - 16.0).abs() > 1.0)
}

///|
test "stats merge ignores shards that hold no values" {
  let empty : @moonseek.StatSummary = {
    count: 0,
    min: 0.0,
    max: 0.0,
    avg: 0.0,
    sum: 0.0,
  }
  let some : @moonseek.StatSummary = {
    count: 2,
    min: 5.0,
    max: 9.0,
    avg: 7.0,
    sum: 14.0,
  }
  let replies : Array[AggReply] = [
    { results: [agg_stats("v", empty)], values: [], },
    { results: [agg_stats("v", some)], values: [], },
  ]
  let merged = merge_aggregates([@moonseek.StatsAgg("v")], replies)
  let st = merged[0].stats.unwrap()
  assert_eq(st.count, 2)
  // A shard with no values reports min/max 0.0; letting those through would
  // drag the minimum to zero.
  assert_eq(st.min, 5.0)
  assert_eq(st.max, 9.0)
}

///|
test "merged histogram buckets sort by bucket, not by label text" {
  let replies : Array[AggReply] = [
    { results: [agg_histogram("v", [("0", 1.0), ("10", 2.0)])], values: [], },
    { results: [agg_histogram("v", [("2", 3.0)])], values: [], },
  ]
  let merged = merge_aggregates([@moonseek.HistogramAgg("v", 2.0)], replies)
  let labels : Array[String] = []
  for (label, _) in merged[0].buckets {
    labels.push(label)
  }
  // As text this sorts "0", "10", "2". As buckets it is 0, 2, 10.
  assert_eq(labels, ["0", "2", "10"])
  assert_eq(merged[0].buckets[1], ("2", 3.0))
}

///|
test "percentiles merge from the raw values, not from per-shard percentiles" {
  // Two shards with disjoint ranges. Their medians are 2 and 20, so the average
  // of the medians is 11; the median of the union is 6.5.
  let low : Array[Double] = [1.0, 2.0, 3.0]
  let high : Array[Double] = [10.0, 20.0, 30.0]
  let replies : Array[AggReply] = [
    { results: [agg_percentiles("v", [(50.0, 2.0)])], values: [("v", low)], },
    { results: [agg_percentiles("v", [(50.0, 20.0)])], values: [("v", high)], },
  ]
  let merged = merge_aggregates(
    [@moonseek.PercentilesAgg("v", [50.0])],
    replies,
  )
  let p50 = merged[0].percentiles[0].1
  assert_true((p50 - 6.5).abs() < 1.0e-9)
  // And it is not the per-shard answer, which is what a summary-only merge
  // would have produced.
  assert_true((p50 - 11.0).abs() > 1.0)
}

///|
test "percentiles_of sorts a copy and leaves the caller's array alone" {
  let values : Array[Double] = [3.0, 1.0, 2.0]
  let out = @moonseek.percentiles_of(values, [0.0, 100.0])
  assert_eq(out[0].1, 1.0)
  assert_eq(out[1].1, 3.0)
  assert_eq(values, [3.0, 1.0, 2.0])
}

///|
test "filters travel to the shards as valid JSON" {
  let filters : Array[(String, Array[String])] = [
    ("license", ["MIT", "Apache-2.0"]),
    ("domain", ["wasm"]),
  ]
  let json = filters_json(filters)
  let parsed = @json.parse(json) catch {
    _ => abort("filters_json is not JSON")
  }
  match parsed {
    Array(items) => {
      assert_eq(items.length(), 2)
      match items[0] {
        Array(pair) => {
          assert_eq(pair.length(), 2)
          match pair[0] {
            String(field) => assert_eq(field, "license")
            _ => abort("field is not a string")
          }
          match pair[1] {
            Array(values) => assert_eq(values.length(), 2)
            _ => abort("values are not an array")
          }
        }
        _ => abort("filter is not a pair")
      }
    }
    _ => abort("filters_json is not an array")
  }
  assert_eq(filters_json([]), "[]")
  // A filter value with a quote in it must not break the request.
  let quoted : Array[(String, Array[String])] = [("name", ["a\"b"])]
  let _ = @json.parse(filters_json(quoted)) catch {
    _ => abort("a quoted filter value broke the JSON")
  }
}

///|
test "doc_id_of reads an id without applying the document" {
  assert_eq(doc_id_of("{\"id\":\"pkg/1\",\"fields\":{}}"), Some("pkg/1"))
  assert_eq(doc_id_of("{\"fields\":{}}"), None)
  assert_eq(doc_id_of("{\"id\":7}"), None)
  assert_eq(doc_id_of("not json"), None)
}

///|
/// Sort orders on the wire.
///
/// The parser has to *reject* what it does not understand. A silent fall back to
/// score order is the exact failure this parameter was documented to fix: a
/// client asks for a field order, gets score order, and has no way to tell.

///|
test "sort specs parse with the documented defaults per field" {
  // Score and numbers descend by default (a "top N" is the largest); ids ascend
  // (a listing is A to Z).
  assert_true(parse_sort("score", "") is Some(@moonseek.ScoreDesc))
  assert_true(parse_sort("", "") is Some(@moonseek.ScoreDesc))
  assert_true(parse_sort("id", "") is Some(@moonseek.IdAsc))
  assert_true(parse_sort("num:year", "") is Some(@moonseek.NumDesc("year")))
  // Explicit order wins in both directions.
  assert_true(parse_sort("score", "asc") is Some(@moonseek.ScoreAsc))
  assert_true(parse_sort("id", "desc") is Some(@moonseek.IdDesc))
  assert_true(parse_sort("num:year", "asc") is Some(@moonseek.NumAsc("year")))
  // Case and whitespace are tolerated.
  assert_true(
    parse_sort(" NUM:Year ", " DESC ") is Some(@moonseek.NumDesc("year")),
  )
}

///|
test "an unrecognized sort is rejected rather than ignored" {
  assert_true(parse_sort("year", "") is None)
  assert_true(parse_sort("num:", "") is None)
  assert_true(parse_sort("num", "") is None)
  assert_true(parse_sort("score", "sideways") is None)
  assert_true(parse_sort("score", "ascending") is None)
  // A name that merely starts with the prefix is not a number sort.
  assert_true(parse_sort("number:year", "") is None)
}

///|
test "sort names round-trip through the wire form" {
  let cases : Array[@moonseek.SortOrder] = [
    @moonseek.ScoreDesc,
    @moonseek.ScoreAsc,
    @moonseek.IdAsc,
    @moonseek.IdDesc,
    @moonseek.NumAsc("year"),
    @moonseek.NumDesc("versions"),
  ]
  for sort in cases {
    let by = sort_by_name(sort)
    let order = sort_order_name(sort)
    // Parsing the wire form must give back the same order, or a coordinator
    // would ask the shards for one order and merge as if it were another.
    match parse_sort(by, order) {
      Some(parsed) => assert_eq(parsed, sort)
      None => abort("wire form did not parse: " + by + " " + order)
    }
  }
}

///|
test "the merge comparator mirrors the engine's ordering rules" {
  let older : ShardHit = { id: "a", score: 1.0, key: 5.0, }
  let newer : ShardHit = { id: "b", score: 1.0, key: 9.0, }
  // Descending by the key, even though a has the lower score.
  assert_true(compare_shard_hits(@moonseek.NumDesc("k"), newer, older) < 0)
  assert_true(compare_shard_hits(@moonseek.NumAsc("k"), newer, older) > 0)
  // The sign flips between the two directions for a pair that both have.
  assert_eq(
    compare_shard_hits(@moonseek.NumDesc("k"), older, newer),
    -compare_shard_hits(@moonseek.NumDesc("k"), newer, older),
  )
  // A missing key sorts last in both directions.
  let undated : ShardHit = { id: "c", score: 1.0, key: missing_key(), }
  assert_true(compare_shard_hits(@moonseek.NumDesc("k"), older, undated) < 0)
  assert_true(compare_shard_hits(@moonseek.NumAsc("k"), older, undated) < 0)
  assert_true(compare_shard_hits(@moonseek.NumAsc("k"), undated, older) > 0)
  // Score order ignores the key entirely. Equal scores (these two) break by id,
  // so the comparison is a tie-break rather than a real ordering: "a" first.
  assert_true(compare_shard_hits(@moonseek.ScoreDesc, older, newer) < 0)
  assert_true(compare_shard_hits(@moonseek.ScoreDesc, newer, older) > 0)
}

///|
test "a shard reply carries the sort key and tolerates its absence" {
  let with_key = parse_shard_hits(
    "{\"hits\":[[\"x\",1.5,7],[\"y\",0.5,null]],\"total\":2}",
  )
  assert_true(with_key.ok)
  assert_eq(with_key.hits.length(), 2)
  assert_eq(with_key.hits[0].id, "x")
  assert_eq(with_key.hits[0].key, 7.0)
  // An explicit null and a missing third element both mean "no value", which is
  // what an older shard sends.
  assert_true(@moonseek.is_missing_number(with_key.hits[1].key))
  let old_shape = parse_shard_hits("{\"hits\":[[\"z\",2.0]],\"total\":1}")
  assert_eq(old_shape.hits[0].id, "z")
  assert_eq(old_shape.hits[0].score, 2.0)
  assert_true(@moonseek.is_missing_number(old_shape.hits[0].key))
}

///|
/// The migration and the planner have to agree on *which* documents move, not
/// just on how many. If the executor's selection diverged from the planner's, a
/// rebalance would move a different set than the operator was shown — and the
/// end-to-end test would only catch it if the two counts happened to differ.

///|
test "the migration selects exactly the ids the planner counted" {
  let ids : Array[String] = []
  for i in 0..<2000 {
    ids.push("pkg/\{i}")
  }
  let plan = rebalance_plan(ids, 3, 4, Ring)
  let ring_from = build_ring(3)
  let ring_to = build_ring(4)
  let mut selected = 0
  for id in ids {
    if ring_from.owner(id) != ring_to.owner(id) {
      selected = selected + 1
      // Everything selected has a real destination, or the executor would index
      // out of bounds building its per-destination buckets.
      let dest = ring_to.owner(id)
      assert_true(dest >= 0 && dest < 4)
    }
  }
  assert_eq(selected, plan.moved)
  // The same rule read the other way: an id the two rings agree about is never
  // touched. This is what makes a repeated rebalance a no-op rather than a
  // second round of moves.
  let mut stayed = 0
  for id in ids {
    if ring_from.owner(id) == ring_to.owner(id) {
      stayed = stayed + 1
    }
  }
  assert_eq(stayed + selected, ids.length())
  assert_eq(plan.moved, selected)
}

///|
test "the rebalance plan makes the same claim as the ring arrays it returns" {
  let ids : Array[String] = []
  for i in 0..<1500 {
    ids.push("pkg/\{i}")
  }
  for (from_shards, to_shards) in [(3, 4), (4, 3), (3, 5), (6, 2)] {
    let plan = rebalance_plan(ids, from_shards, to_shards, Ring)
    let mut before_sum = 0
    for count in plan.before {
      before_sum = before_sum + count
    }
    let mut after_sum = 0
    for count in plan.after {
      after_sum = after_sum + count
    }
    // Every id is in exactly one bucket on each side, so the counts have to add
    // up. A ring that dropped or duplicated a key would show here.
    assert_eq(before_sum, plan.total)
    assert_eq(after_sum, plan.total)
    assert_eq(plan.before.length(), from_shards)
    assert_eq(plan.after.length(), to_shards)
  }
}

///|
test "the bulk request is valid JSON with the documents embedded" {
  let request = bulk_request(["{\"id\":\"a\"}", "{\"id\":\"b\"}"])
  let parsed = @json.parse(request) catch {
    _ => abort("bulk_request is not JSON")
  }
  match parsed {
    Object(fields) => {
      match fields.get("op") {
        Some(String(op)) => assert_eq(op, "bulk")
        _ => abort("missing op")
      }
      match fields.get("body") {
        Some(String(body)) => {
          // Newline-delimited, which is what the shard's bulk op splits on.
          let lines : Array[String] = []
          for line in body.split("\n") {
            if !line.trim().is_empty() {
              lines.push(line.to_owned())
            }
          }
          assert_eq(lines.length(), 2)
        }
        _ => abort("missing body")
      }
    }
    _ => abort("not an object")
  }
  // A document containing a quote must not break the framing.
  let quoted = bulk_request(["{\"id\":\"a\\\"b\"}"])
  let _ = @json.parse(quoted) catch { _ => abort("a quoted id broke the JSON") }
}
