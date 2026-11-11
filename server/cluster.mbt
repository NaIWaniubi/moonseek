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
  timeout_ms : Int32
} derive(Eq, Debug)

///|
pub extend ClusterConfig with Eq::{equal, not_equal}

///|
pub extend ClusterConfig with @debug.Debug::{to_repr}

///|
/// FNV-1a over the **UTF-8 bytes** of a string.
///
/// Byte-wise, not code-unit-wise: this hashes `@utf8.encode(text)`, so the
/// offline splitter in `tools/make-shard-corpus.mjs` (which hashes
/// `Buffer.from(id, "utf8")`) and this function agree for non-ASCII ids too.
/// An earlier version hashed `String::to_array()`, which is UTF-16, so a CJK id
/// would have hashed differently in the coordinator and in the splitter. That
/// went unnoticed only because every generated id was ASCII, where the low byte
/// of a UTF-16 unit equals the UTF-8 byte. There is a cross-language golden
/// test for this (`hashing" in server/cluster_wbtest.mbt`).
pub fn fnv1a(text : String) -> UInt32 {
  let mut hash : UInt32 = 2166136261U
  for b in @utf8.encode(text) {
    hash = hash ^ (b.to_int().reinterpret_as_uint() & 0xFFU)
    hash = hash * 16777619U
  }
  hash
}

///|
/// MurmurHash3's 32-bit finalizer.
fn fmix32(x : UInt32) -> UInt32 {
  let mut h = x
  h = h ^ (h >> 16)
  h = h * 0x85EBCA6BU
  h = h ^ (h >> 13)
  h = h * 0xC2B2AE35U
  h = h ^ (h >> 16)
  h
}

///|
/// The hash a cluster places a key with: FNV-1a mixed through `fmix32`.
///
/// FNV-1a on its own is **linear** in the input bytes — `pkg/1`, `pkg/2`, …
/// differ only in the last byte, so their hashes sit in an arithmetic
/// progression with step `16777619` and cluster. That is harmless for
/// `hash % N`, which only needs the low bits, but it wrecks a hash ring: a ring
/// whose *points* are built from such keys measured **29% / 21% / 50%** behind
/// three shards. The Murmur3 finalizer breaks the linearity and the same ring
/// measures **36% / 28% / 36%**, with real id sets landing within 5% of even.
/// One multiply chain, and it is the reason the ring is usable at all.
pub fn hash_key(text : String) -> UInt32 {
  fmix32(fnv1a(text))
}

///|
/// Deterministic shard assignment: the key hash modulo the shard count.
/// Deterministic because a document must return to the same shard on every
/// write — otherwise a re-index would leave two copies on different shards and
/// a search would return it twice.
///
/// This is the *modulo* placement. It is kept because it is the honest
/// baseline the ring is measured against: `hash % N` renumbers nearly every
/// key when `N` changes. See `HashRing` and `rebalance_plan`.
pub fn shard_for(id : String, shard_count : Int32) -> Int32 {
  if shard_count <= 0 {
    return 0
  }
  (hash_key(id) % shard_count.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// Virtual nodes per shard on the ring.
///
/// Each shard claims many positions instead of one, which shrinks the arcs and
/// evens out the load. One point per shard would put most of a three-shard ring
/// behind whichever shard happened to land first; at 128 the measured imbalance
/// is a few percent.
pub const RING_VNODES : Int32 = 128

///|
/// A consistent-hash ring: one sorted array of `(position, shard)` points.
///
/// The whole reason it exists is the reshuffle cost. With `hash % N`, adding a
/// shard changes the divisor for every key, so almost every document moves.
/// With a ring, a key belongs to the first point at or after its position, so
/// adding a shard only moves the arcs the new shard's points take over — about
/// `1/N` of the corpus. `rebalance_plan` measures both, and docs/cluster.md
/// quotes the numbers.
pub(all) struct HashRing {
  /// Ascending by position. Positions are unique in practice because the point
  /// hash mixes in the shard index and the virtual-node index.
  points : Array[(UInt32, Int32)]
  shard_count : Int32
} derive(Eq, Debug)

///|
pub extend HashRing with Eq::{equal, not_equal}

///|
pub extend HashRing with @debug.Debug::{to_repr}

///|
/// Build the ring for `shard_count` shards.
///
/// The point hash covers only `shard:<index>#<vn>` — the shard's *position in
/// the list*, never its address. Moving a shard to another host, or renaming
/// it, must not move a single document; only adding or removing a shard should.
pub fn build_ring(
  shard_count : Int32,
  vnodes~ : Int32 = RING_VNODES,
) -> HashRing {
  let points : Array[(UInt32, Int32)] = []
  if shard_count > 0 && vnodes > 0 {
    for s in 0..<shard_count {
      let prefix = "shard:" + s.to_string() + "#"
      for v in 0..<vnodes {
        points.push((hash_key(prefix + v.to_string()), s))
      }
    }
  }
  points.sort_by(fn(a, b) {
    let c = a.0.compare(b.0)
    if c == 0 {
      a.1.compare(b.1)
    } else {
      c
    }
  })
  { points, shard_count, }
}

///|
/// The shard that owns a key: the first ring point at or after the key's
/// position, wrapping to the first point when the key falls past the last one.
pub fn HashRing::owner(self : HashRing, id : String) -> Int32 {
  if self.points.length() == 0 {
    return 0
  }
  let target = hash_key(id)
  // Lower bound: the first point whose position is >= the key.
  let mut lo = 0
  let mut hi = self.points.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if self.points[mid].0 < target {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let idx = if lo >= self.points.length() { 0 } else { lo }
  self.points[idx].1
}

///|
/// Which placement rule a coordinator uses.
pub(all) enum ShardMode {
  /// Consistent hashing: `HashRing::owner`.
  Ring
  /// `hash(id) % shards`. Kept for the reshuffle comparison.
  Modulo
} derive(Eq, Debug)

///|
pub extend ShardMode with Eq::{equal, not_equal}

///|
pub extend ShardMode with @debug.Debug::{to_repr}

///|
/// Parse `ring` / `modulo`, defaulting to the ring. An unknown word is an error
/// rather than a silent fallback: a coordinator that quietly used a different
/// rule than the operator asked for would place documents somewhere the
/// operator's own tooling disagrees with.
pub fn parse_shard_mode(text : String) -> ShardMode? {
  match text.trim().to_lower() {
    "ring" | "hashring" | "consistent" | "" => Some(Ring)
    "modulo" | "mod" => Some(Modulo)
    _ => None
  }
}

///|
/// Where a set of ids lands, before and after a change of shard count, and how
/// much moved.
pub(all) struct Rebalance {
  before : Array[Int32]
  after : Array[Int32]
  /// Ids whose owning shard index changed.
  moved : Int32
  total : Int32
} derive(Eq, Debug)

///|
pub extend Rebalance with Eq::{equal, not_equal}

///|
pub extend Rebalance with @debug.Debug::{to_repr}

///|
/// Plan a change of shard count: how the ids distribute now, how they would
/// distribute afterwards, and the fraction that has to be copied.
///
/// This is the number that decides whether a cluster can grow without a
/// rewrite, so it is computed from the real ids rather than estimated.
pub fn rebalance_plan(
  ids : Array[String],
  from_shards : Int32,
  to_shards : Int32,
  mode : ShardMode,
) -> Rebalance {
  let before = Array::make(from_shards, 0)
  let after = Array::make(to_shards, 0)
  let mut moved = 0
  let ring_before = build_ring(from_shards)
  let ring_after = build_ring(to_shards)
  for id in ids {
    let b = match mode {
      Ring => ring_before.owner(id)
      Modulo => shard_for(id, from_shards)
    }
    let a = match mode {
      Ring => ring_after.owner(id)
      Modulo => shard_for(id, to_shards)
    }
    if b >= 0 && b < before.length() {
      before[b] = before[b] + 1
    }
    if a >= 0 && a < after.length() {
      after[a] = after[a] + 1
    }
    // Only a key's *index* matters for movement. Under the ring a key that
    // stays on "shard 1" has not moved even though the ring was rebuilt, so
    // comparing indices is the right test, not comparing arcs.
    if a != b {
      moved = moved + 1
    }
  }
  { before, after, moved, total: ids.length(), }
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
  sock.write(frame(payload)) catch {
    _ => return None
  }
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
      { hits, total, ok: true, }
    }
    _ => failed_shard()
  }
}

///|
fn failed_shard() -> ShardHits {
  { hits: [], total: 0, ok: false, }
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
          @json.to_json(stat_key(key.0, key.1)).stringify() +
          ":" +
          count.to_string(),
        )
      }
      let avgdl_entries : Array[String] = []
      for (field, value) in s.avgdl.iter() {
        avgdl_entries.push(
          @json.to_json(field).stringify() + ":" + value.to_string(),
        )
      }
      ",\"stats\":{\"n\":" +
      s.n.to_string() +
      ",\"df\":{" +
      df_entries.join(",") +
      "},\"avgdl\":{" +
      avgdl_entries.join(",") +
      "}}"
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
  let cap = if limit <= 0 || hits.length() < limit {
    hits.length()
  } else {
    limit
  }
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
      "[" +
      @json.to_json(term).stringify() +
      "," +
      @json.to_json(field).stringify() +
      "]",
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
/// The key form used between coordinator and shard: `field\u{0}term`.
pub fn stat_key(field : String, term : String) -> String {
  field + "\u{0}" + term
}

///|
/// The members of a shard group in preference order: the primary, then its
/// replicas.
pub fn group_members(group : ShardGroup) -> Array[String] {
  let out : Array[String] = [group.primary]
  for replica in group.replicas {
    out.push(replica)
  }
  out
}

///|
/// A shard reply counts as an acknowledgement when it is an object without an
/// `error` field. Both `{"ok":true,…}` and `{"indexed":3,…}` qualify, and an
/// `{"error":…}` never does. That is the property the coordinator needs: a
/// transport that succeeded but a write that failed must not be counted.
fn reply_ok(text : String) -> Bool {
  match parse_json_or_none(text) {
    Some(Object(fields)) => !fields.contains("error")
    _ => false
  }
}

///|
/// What one shard group did with a write.
pub(all) struct WriteAck {
  /// Members that applied the write.
  acked : Int32
  /// Members the write was sent to.
  members : Int32
  /// Members that did not apply it, named so a caller can act.
  failed : Array[String]
  /// The first member's reply that counted as an acknowledgement, so a caller
  /// can read write-specific counters such as `indexed`. Empty when none did.
  reply : String
} derive(Eq, Debug)

///|
pub extend WriteAck with Eq::{equal, not_equal}

///|
pub extend WriteAck with @debug.Debug::{to_repr}

///|
/// Send one write request to **every** member of a group, in parallel.
///
/// Replicating on the write path is what makes a replica a replica. Without it
/// a replica is only correct if someone seeded it by hand, so the failover path
/// answers from stale data while reporting success — the worst kind of failure,
/// because it looks like a working cluster. Writing to every member costs one
/// round trip to each of them, and they run in parallel with the primary's.
async fn write_group(group : ShardGroup, request : String) -> WriteAck {
  let members = group_members(group)
  let answers : Array[String?] = Array::make(members.length(), None)
  @async.with_task_group(fn(tasks) {
    for i in 0..<members.length() {
      let index = i
      let _ = tasks.spawn(
        async fn() {
          answers[index] = shard_call(members[index], request)
        },
        allow_failure=true,
      )
    }
  })
  let mut acked = 0
  let mut reply = ""
  let failed : Array[String] = []
  for i in 0..<members.length() {
    match answers[i] {
      Some(text) =>
        if reply_ok(text) {
          acked = acked + 1
          if reply == "" {
            reply = text
          }
        } else {
          failed.push(members[i])
        }
      None => failed.push(members[i])
    }
  }
  { acked, members: members.length(), failed, reply }
}

///|
/// Read `"id"` out of a document body without applying it, so a coordinator can
/// decide which shard owns a document before sending it anywhere. Returns None
/// for anything that is not an object with a string id, which the caller
/// reports as a bad request rather than guessing a shard.
pub fn doc_id_of(body : String) -> String? {
  match parse_json_or_none(body) {
    Some(Object(fields)) =>
      match fields.get("id") {
        Some(String(id)) => Some(id)
        _ => None
      }
    _ => None
  }
}

///|
/// Collect every live document id from every shard.
///
/// Used by the rebalance planner. It reads the real keys rather than a sample,
/// because "how much would move" is only worth reporting if it is the actual
/// answer for this corpus. A failed shard contributes nothing and is reported,
/// so a plan built on a partial corpus is visibly partial.
async fn cluster_all_ids(
  config : ClusterConfig,
) -> (Array[String], Array[String]) {
  let request = "{\"op\":\"ids\"}"
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
  let ids : Array[String] = []
  let failed : Array[String] = []
  for i in 0..<config.shards.length() {
    let (answer, address) = answers[i]
    match answer {
      Some(text) => {
        let parsed = match parse_json_or_none(text) {
          Some(j) => j
          None => {
            failed.push(address)
            continue
          }
        }
        match parsed {
          Object(fields) =>
            match fields.get("ids") {
              Some(Array(items)) =>
                for item in items {
                  if item is String(id) {
                    ids.push(id)
                  }
                }
              _ => failed.push(address)
            }
          _ => failed.push(address)
        }
      }
      None => failed.push(address)
    }
  }
  (ids, failed)
}

///|
/// Extract the (field, term) pairs a parsed query would score. The coordinator
/// must ask for exactly these or the global statistics will be incomplete and
/// the two-phase ranking will differ from a single-node index in a way the
/// tests cannot explain.
pub fn query_terms(
  index : @moonseek.Index,
  query : String,
) -> Array[(String, String)]? {
  let fields : Array[String] = []
  for f in index.schema() {
    fields.push(f.name)
  }
  let parsed = @moonseek.parse_query(query, analyzer=index.analyzer(), fields~) catch {
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
      [primary] => out.push({ primary, replicas: [], })
      [primary, ..] => {
        let replicas : Array[String] = []
        for i in 1..<parts.length() {
          replicas.push(parts[i])
        }
        out.push({ primary, replicas, })
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
  let head : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  head[0] = (len & 0xFF).to_byte()
  head[1] = ((len >> 8) & 0xFF).to_byte()
  head[2] = ((len >> 16) & 0xFF).to_byte()
  head[3] = ((len >> 24) & 0xFF).to_byte()
  Bytes::from_array(head) + payload
}

///|
/// Decode a 4-byte little-endian length prefix.
pub fn unframe_length(header : BytesView) -> Int32 {
  header[0].to_int() |
  (header[1].to_int() << 8) |
  (header[2].to_int() << 16) |
  (header[3].to_int() << 24)
}

///|
/// Parse JSON, collapsing a parse error into None: shard replies arrive over
/// the network, so a malformed one is a handled case rather than a panic.
fn parse_json_or_none(text : String) -> Json? {
  Some(@json.parse(text)) catch {
    _ => None
  }
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
          @json.to_json(stat_key(key.0, key.1)).stringify() +
          ":" +
          count.to_string(),
        )
      }
      let avgdl_entries : Array[String] = []
      for (field, value) in s.avgdl.iter() {
        avgdl_entries.push(
          @json.to_json(field).stringify() + ":" + value.to_string(),
        )
      }
      "{\"n\":" +
      s.n.to_string() +
      ",\"df\":{" +
      df_entries.join(",") +
      "},\"avgdl\":{" +
      avgdl_entries.join(",") +
      "}}"
    }
  }
}
