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
