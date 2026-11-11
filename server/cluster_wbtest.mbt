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
    "",
    "{}",
    "{\"op\":\"search\",\"query\":\"parser\"}",
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
    Object(fields) => {
      match fields.get("stats") {
        Some(Object(inner)) =>
          match inner.get("n") {
            Some(Number(n, ..)) => assert_eq(n.to_int(), 3000)
            _ => abort("missing n")
          }
        _ => abort("missing stats object")
      }
    }
    _ => abort("not an object")
  }
}

///|
test "a search request carrying statistics is valid JSON" {
  let stats = @moonseek.ExternalStats::new(
    100,
    df=[(("body", "x"), 1)],
    avgdl=[("body", 5.0)],
  )
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
  let idx = @moonseek.Index::new([{ name: "body", weight: 1.0 }])
  idx.add({ id: "a", fields: [("body", "parser")] })
  assert_true(query_terms(idx, "parser") is Some(_))
  assert_true(query_terms(idx, "par*") is None)
  // An unparseable query is also None rather than an error.
  assert_true(query_terms(idx, "\"unterminated") is None)
}
