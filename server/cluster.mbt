///|
/// The distributed layer: shard nodes and the coordinator that queries them.
///
/// Shape: one binary that can run as a single node, as a *shard*, or as a
/// *coordinator*. A shard owns one index and answers a small line-oriented
/// protocol over TCP. A coordinator keeps no index at all — it shards incoming
/// writes by id hash, fans a query out to every shard in parallel, merges the
/// per-shard top-k, and reports which shards answered.
///
/// Why a coordinator that owns nothing: it is the only shape that survives a
/// shard dying. If the coordinator held a slice of the data too, losing that
/// slice would lose data rather than just capacity, and the failover logic
/// would have to special-case itself.
///
/// Two scoring modes, because they trade a round trip for correctness:
///   * **local statistics** (default) — one round trip. Each shard scores with
///     its own `N`, `df` and `avgdl`, so the same document gets a slightly
///     different score depending on which shard holds it.
///   * **global statistics** (`dfs=true`) — two round trips. The coordinator
///     gathers `df`/`avgdl`/`N` from every shard, then asks each shard to score
///     with those, which makes the ranking identical to a single-node index of
///     the same corpus. This is Elasticsearch's `dfs_query_then_fetch`, and the
///     cluster test measures the difference rather than asserting it away.

///|
/// One shard: a primary address and its replicas, in preference order.
pub(all) struct ShardGroup {
  primary : String
  replicas : Array[String]
} derive(Eq, Debug)

///|
pub extend ShardGroup with Eq::{equal, not_equal}

///|
pub extend ShardGroup with @debug.Debug::{to_repr}

///|
/// Coordinator configuration.
pub(all) struct ClusterConfig {
  shards : Array[ShardGroup]
  /// Per-shard candidate pool: how many hits each shard returns before the
  /// coordinator takes the global top-k. Must be >= the requested limit or the
  /// merge cannot be correct; a coordinator that asks for exactly `limit` from
  /// every shard can miss a document that is rank `limit+1` locally but top-10
  /// globally.
  pool_per_shard : Int32
  /// Milliseconds before a shard is considered unavailable.
  timeout_ms : Int
} derive(Eq, Debug)

///|
pub extend ClusterConfig with Eq::{equal, not_equal}

///|
pub extend ClusterConfig with @debug.Debug::{to_repr}

///|
/// Deterministic shard assignment: FNV-1a over the id. Deterministic because a
/// document must return to the same shard on every write — otherwise a
/// re-index would leave two copies on different shards and a search would
/// return it twice.
pub fn shard_for(id : String, shard_count : Int32) -> Int32 {
  if shard_count <= 0 {
    return 0
  }
  let mut hash : UInt32 = 2166136261U
  for c in id.to_array() {
    hash = hash ^ (c.to_int().reinterpret_as_uint() & 0xFFU)
    hash = hash * 16777619U
  }
  (hash % shard_count.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// One shard's answer to a search.
struct ShardHits {
  /// (id, score) pairs, already sorted by the shard.
  hits : Array[(String, Double)]
  /// Total matches, for the merged `total`.
  total : Int32
  /// Whether the shard answered at all.
  ok : Bool
}

///|
/// Send one line of JSON to a shard and read one line back. Returns None when
/// the shard cannot be reached, which the caller turns into failover.
///
/// One request per connection keeps the protocol trivial to reason about: there
/// is no pipelining, no framing beyond a newline, and a half-written request
/// can only affect the connection it was sent on.
async fn shard_call(addr_text : String, request : String) -> String? {
  let addr = @socket.Addr::parse(addr_text) catch { _ => return None }
  let sock = @socket.Tcp::connect(addr) catch { _ => return None }
  defer sock.close()
  let payload = @utf8.encode(request)
  // Length-prefixed framing, not newline-terminated. A newline delimiter only
  // works if the reader can tell a complete message from a partial one, and
  // reading to EOF deadlocks: the client waits for the answer while the server
  // waits for a close that never comes. A 4-byte little-endian length makes
  // both sides independent.
  sock.write(frame(payload)) catch { _ => return None }
  let reply_header = sock.read_exactly(4) catch { _ => return None }
  let length = unframe_length(reply_header)
  if length <= 0 {
    return Some("")
  }
  let body = sock.read_exactly(length) catch { _ => return None }
  Some(@utf8.decode(body) catch { _ => "" })
}

///|
/// Try a shard group in order: primary first, then replicas. Returns the first
/// answer that arrives, together with the address that gave it.
async fn call_group(group : ShardGroup, request : String) -> (String?, String) {
  let primary = match shard_call(group.primary, request) {
    Some(answer) => return (Some(answer), group.primary)
    None => group.primary
  }
  for replica in group.replicas {
    match shard_call(replica, request) {
      Some(answer) => return (Some(answer), replica)
      None => ()
    }
  }
  (None, primary)
}

///|
/// Parse a shard's search answer into hits.
fn parse_shard_hits(answer : String) -> ShardHits {
  let json = match parse_json_or_none(answer) {
    Some(j) => j
    None => return failed_shard()
  }
  match json {
    Object(fields) => {
      let hits : Array[(String, Double)] = []
      match fields.get("hits") {
        Some(Array(items)) =>
          for item in items {
            match item {
              Array(pair) if pair.length() == 2 =>
                match (pair[0], pair[1]) {
                  (String(id), Number(score, ..)) => hits.push((id, score))
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
      let total = match fields.get("total") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      { hits, total, ok: true }
    }
    _ => failed_shard()
  }
}

///|
fn failed_shard() -> ShardHits {
  { hits: [], total: 0, ok: false }
}

///|
/// The merged answer a coordinator returns.
pub(all) struct ClusterResult {
  /// Global top-k after merging the shards' candidates.
  hits : Array[(String, Double)]
  /// Sum of the shards' match counts.
  total : Int32
  shards_total : Int32
  shards_ok : Int32
  shards_failed : Int32
  /// Addresses that did not answer, for the diagnostics panel.
  failed : Array[String]
} derive(Eq, Debug)

///|
pub extend ClusterResult with Eq::{equal, not_equal}

///|
pub extend ClusterResult with @debug.Debug::{to_repr}

///|
/// Render the `stats` block a shard needs for globally consistent scoring, or
/// nothing when the coordinator is using local statistics.
pub fn stats_clause(stats : @moonseek.ExternalStats?) -> String {
  match stats {
    None => ""
    Some(s) => {
      let df_entries : Array[String] = []
      for (key, count) in s.df.iter() {
        df_entries.push(
          @json.to_json(stat_key(key.0, key.1)).stringify() + ":" +
          count.to_string(),
        )
      }
      let avgdl_entries : Array[String] = []
      for (field, value) in s.avgdl.iter() {
        avgdl_entries.push(
          @json.to_json(field).stringify() + ":" + value.to_string(),
        )
      }
      ",\"stats\":{\"n\":" + s.n.to_string() + ",\"df\":{" +
      df_entries.join(",") + "},\"avgdl\":{" + avgdl_entries.join(",") + "}}"
    }
  }
}

///|
/// Scatter-gather search across the cluster.
///
/// Every shard is queried in parallel; a shard that fails (or whose replicas
/// all fail) is reported rather than aborting the query, because a partial
/// answer with an explicit failure count is more useful than an error, and the
/// count is what tells a client the answer is partial.
async fn cluster_search(
  config : ClusterConfig,
  query : String,
  limit : Int32,
  stats : @moonseek.ExternalStats?,
) -> ClusterResult {
  let pool = if config.pool_per_shard < limit {
    limit
  } else {
    config.pool_per_shard
  }
  // The query is escaped once and embedded in each request.
  let request = "{\"op\":\"search\",\"query\":" +
    @json.to_json(query).stringify() +
    ",\"limit\":" +
    pool.to_string() +
    stats_clause(stats) +
    "}"
  let answers : Array[(String?, String)] = Array::make(
    config.shards.length(),
    (None, ""),
  )
  @async.with_task_group(fn(group) {
    for i in 0..<config.shards.length() {
      let index = i
      let shard = config.shards[index]
      let _ = group.spawn(
        async fn() {
          let (answer, address) = call_group(shard, request)
          answers[index] = (answer, address)
        },
        allow_failure=true,
      )
    }
  })
  let hits : Array[(String, Double)] = []
  let failed : Array[String] = []
  let mut total = 0
  let mut ok = 0
  for i in 0..<config.shards.length() {
    let (answer, address) = answers[i]
    let parsed = match answer {
      Some(text) => parse_shard_hits(text)
      None => failed_shard()
    }
    if parsed.ok {
      ok += 1
      total += parsed.total
      for h in parsed.hits {
        hits.push(h)
      }
    } else {
      failed.push(address)
    }
  }
  hits.sort_by(fn(a, b) {
    let cmp = b.1.compare(a.1)
    if cmp == 0 {
      a.0.lexical_compare(b.0)
    } else {
      cmp
    }
  })
  let top : Array[(String, Double)] = []
  let cap = if limit <= 0 || hits.length() < limit { hits.length() } else { limit }
  for i in 0..<cap {
    top.push(hits[i])
  }
  {
    hits: top,
    total,
    shards_total: config.shards.length(),
    shards_ok: ok,
    shards_failed: failed.length(),
    failed,
  }
}

///|
/// Gather corpus-wide statistics from every shard: live document count, the
/// document frequency of each query term, and the average length of each
/// field. This is phase one of `dfs_query_then_fetch`.
///
/// `terms` is the (field, term) list the coordinator extracted from the parsed
/// query. Only those are fetched, because those are the only ones scoring reads.
async fn cluster_gather_stats(
  config : ClusterConfig,
  terms : Array[(String, String)],
) -> @moonseek.ExternalStats? {
  // One request carrying every term the coordinator cares about. Each term is a
  // two-element array `["term","field"]`: an earlier version emitted
  // `"term":"field"` inside the array, which is not JSON at all, so every shard
  // answered "bad json" and the coordinator gathered nothing while reporting
  // success.
  let term_json : Array[String] = []
  for (field, term) in terms {
    term_json.push(
      "[" + @json.to_json(term).stringify() + "," +
      @json.to_json(field).stringify() + "]",
    )
  }
  let request = "{\"op\":\"stats\",\"terms\":[" + term_json.join(",") + "]}"
  let answers : Array[String?] = Array::make(config.shards.length(), None)
  @async.with_task_group(fn(group) {
    for i in 0..<config.shards.length() {
      let index = i
      let shard = config.shards[index]
      let _ = group.spawn(
        async fn() {
          let (answer, _) = call_group(shard, request)
          answers[index] = answer
        },
        allow_failure=true,
      )
    }
  })
  let mut n = 0
  let mut answered = 0
  let df : Array[((String, String), Int32)] = []
  // Accumulate df and total field length across shards.
  let df_acc : Map[(String, String), Int32] = Map([])
  let len_acc : Map[String, Double] = Map([])
  let len_count : Map[String, Int32] = Map([])
  for i in 0..<config.shards.length() {
    match answers[i] {
      Some(text) =>
        match parse_json_or_none(text) {
          Some(Object(fields)) => {
            answered += 1
            match fields.get("docs") {
              Some(Number(d, ..)) => n += d.to_int()
              _ => ()
            }
            match fields.get("df") {
              Some(Object(pairs)) =>
                for (key, value) in pairs.iter() {
                  match value {
                    Number(v, ..) => {
                      let parts = stat_key_parts(key)
                      let existing = df_acc.get_or_default(parts, 0)
                      df_acc[parts] = existing + v.to_int()
                    }
                    _ => ()
                  }
                }
              _ => ()
            }
            match fields.get("field_lengths") {
              Some(Object(pairs)) =>
                for (field, value) in pairs.iter() {
                  match value {
                    Number(v, ..) =>
                      len_acc[field] = len_acc.get_or_default(field, 0.0) + v
                    _ => ()
                  }
                }
              _ => ()
            }
            match fields.get("field_counts") {
              Some(Object(pairs)) =>
                for (field, value) in pairs.iter() {
                  match value {
                    Number(v, ..) =>
                      len_count[field] = len_count.get_or_default(field, 0) +
                        v.to_int()
                    _ => ()
                  }
                }
              _ => ()
            }
          }
          _ => ()
        }
      None => ()
    }
  }
  if answered == 0 {
    return None
  }
  for (key, count) in df_acc.iter() {
    df.push((key, count))
  }
  let avgdl : Array[(String, Double)] = []
  for (field, total_len) in len_acc.iter() {
    let count = len_count.get_or_default(field, 0)
    if count > 0 {
      avgdl.push((field, total_len / count.to_double()))
    }
  }
  Some(@moonseek.ExternalStats::new(n, df~, avgdl~))
}

///|
/// The key form used between coordinator and shard.
pub fn stat_key(field : String, term : String) -> String {
  field + "\u{0}" + term
}

///|
/// Extract the (field, term) pairs a parsed query would score. The coordinator
/// must ask for exactly these or the global statistics will be incomplete and
/// the two-phase ranking will differ from a single-node index in a way the
/// tests cannot explain.
pub fn query_terms(index : @moonseek.Index, query : String) -> Array[(String, String)]? {
  let fields : Array[String] = []
  for f in index.schema() {
    fields.push(f.name)
  }
  let parsed = @moonseek.parse_query(
    query,
    analyzer=index.analyzer(),
    fields~,
  ) catch {
    _ => return None
  }
  @moonseek.scoring_terms(index, parsed)
}

///|
/// `--shards host:port,host:port` (or `host:port|replica,host:port`) into groups.
pub fn parse_shards(text : String) -> Array[ShardGroup] {
  let out : Array[ShardGroup] = []
  for entry in text.split(",") {
    let trimmed = entry.trim()
    if trimmed.is_empty() {
      continue
    }
    let parts : Array[String] = []
    for p in trimmed.split("|") {
      parts.push(p.trim().to_owned())
    }
    match parts {
      [primary] => out.push({ primary, replicas: [] })
      [primary, ..] => {
        let replicas : Array[String] = []
        for i in 1..<parts.length() {
          replicas.push(parts[i])
        }
        out.push({ primary, replicas })
      }
      [] => ()
    }
  }
  out
}
///|
/// Frame a payload with a 4-byte little-endian length prefix.
///
/// One helper for both directions. The prefix is built through a `FixedArray`
/// because `Bytes` has no index assignment in MoonBit, and
/// `Bytes::from_fixedarray` is the supported path.
pub fn frame(payload : Bytes) -> Bytes {
  let len = payload.length()
  let head : FixedArray[Byte] = FixedArray::make(4, b' ')
  head[0] = (len & 0xFF).to_byte()
  head[1] = ((len >> 8) & 0xFF).to_byte()
  head[2] = ((len >> 16) & 0xFF).to_byte()
  head[3] = ((len >> 24) & 0xFF).to_byte()
  Bytes::from_array(head) + payload
}

///|
/// Decode a 4-byte little-endian length prefix.
pub fn unframe_length(header : BytesView) -> Int {
  header[0].to_int() |
  (header[1].to_int() << 8) |
  (header[2].to_int() << 16) |
  (header[3].to_int() << 24)
}

///|
/// Parse JSON, collapsing a parse error into None: shard replies arrive over
/// the network, so a malformed one is a handled case rather than a panic.
fn parse_json_or_none(text : String) -> Json? {
  Some(@json.parse(text)) catch { _ => None }
}

///|
/// Split a `"field\u{0}term"` key back into its parts. The NUL
/// separator is unambiguous: no field name and no analyzed term can contain
/// one.
fn stat_key_parts(key : String) -> (String, String) {
  match key.find("\u{0}") {
    Some(idx) => (key[:idx].to_owned(), key[idx + 1:].to_owned())
    None => (key, "")
  }
}

///|
/// The gathered statistics as JSON, for diagnostics. A coordinator bug in the
/// two-phase path shows up here first: a missing `df` entry or an `avgdl` of
/// zero produces a plausible-looking but wrong ranking.
pub fn stats_to_json(stats : @moonseek.ExternalStats?) -> String {
  match stats {
    None => "null"
    Some(s) => {
      let df_entries : Array[String] = []
      for (key, count) in s.df.iter() {
        df_entries.push(
          @json.to_json(stat_key(key.0, key.1)).stringify() + ":" +
          count.to_string(),
        )
      }
      let avgdl_entries : Array[String] = []
      for (field, value) in s.avgdl.iter() {
        avgdl_entries.push(
          @json.to_json(field).stringify() + ":" + value.to_string(),
        )
      }
      "{\"n\":" + s.n.to_string() + ",\"df\":{" + df_entries.join(",") +
      "},\"avgdl\":{" + avgdl_entries.join(",") + "}}"
    }
  }
}
