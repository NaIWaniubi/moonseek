///|
/// moonseek-server: the HTTP search service.
///
/// A thin routing and serialization layer over the library. Everything that
/// decides a result — analysis, scoring, ranking, aggregation — happens in the
/// engine; this file only maps HTTP onto those calls, so the service and the
/// embedded library cannot drift apart.
///
/// The wire contract is docs/api.md, written before the implementation.

///|
/// Process-wide state: the index plus the counters the stats endpoint reports.
/// One struct is enough because `run_forever` runs each request handler to
/// completion on a cooperative scheduler — nothing preempts a handler midway.
struct ServerState {
  mut index : @moonseek.Index
  schema : Array[@moonseek.FieldSchema]
  started_ms : UInt64
  mut queries_served : Int64
  mut indexed_docs : Int64
  mut deleted_docs : Int64
  /// Sum of query durations in milliseconds (@env.now() is ms, not us).
  mut total_query_ms : Double
  mut max_query_ms : Double
  /// Ring buffer of recent query latencies, for a p99 that does not need a
  /// histogram per request and does not grow with traffic.
  recent : Array[Double]
  mut recent_next : Int32
  /// Shards this process coordinates. Empty means "answer from the local
  /// index", which is the single-node case and also the shard case.
  mut cluster : Array[ShardGroup]
  /// Candidate pool asked of each shard before the coordinator's top-k cut.
  mut pool_per_shard : Int32
  /// How a coordinator decides which group owns a document. Defaults to the
  /// consistent-hash ring; `modulo` is kept for the reshuffle comparison.
  mut shard_mode : ShardMode
  /// The ring for the current shard count, built once at startup. Rebuilding it
  /// per write would be O(vnodes · shards) on every document.
  mut ring : HashRing
  /// Virtual nodes per shard, so the balance can be tuned from the command line.
  mut vnodes : Int32
}

///|
fn ServerState::new(schema : Array[@moonseek.FieldSchema]) -> ServerState {
  {
    index: @moonseek.Index::new(schema),
    schema,
    started_ms: @env.now(),
    queries_served: 0,
    indexed_docs: 0,
    deleted_docs: 0,
    total_query_ms: 0.0,
    max_query_ms: 0.0,
    recent: Array::make(1024, 0.0),
    recent_next: 0,
    cluster: [],
    pool_per_shard: 200,
    shard_mode: Ring,
    ring: build_ring(0),
    vnodes: RING_VNODES,
  }
}

///|
/// The shard group that owns a document, under the coordinator's placement
/// rule. A single node (`cluster` empty) owns everything.
fn ServerState::group_for(self : ServerState, id : String) -> Int32 {
  if self.cluster.is_empty() {
    return -1
  }
  match self.shard_mode {
    Ring => self.ring.owner(id)
    Modulo => shard_for(id, self.cluster.length())
  }
}

///|
fn ServerState::observe_query(self : ServerState, ms : Double) -> Unit {
  self.queries_served += 1
  self.total_query_ms += ms
  if ms > self.max_query_ms {
    self.max_query_ms = ms
  }
  self.recent[self.recent_next] = ms
  self.recent_next = (self.recent_next + 1) % self.recent.length()
}

///|
fn ServerState::avg_query_ms(self : ServerState) -> Double {
  if self.queries_served == 0 {
    0.0
  } else {
    self.total_query_ms / self.queries_served.to_double()
  }
}

///|
/// p99 over the filled prefix of the ring buffer, so the number is right from
/// the first request instead of being diluted by unused zeros.
fn ServerState::p99_query_ms(self : ServerState) -> Double {
  let filled = if self.queries_served < self.recent.length().to_int64() {
    self.recent_next
  } else {
    self.recent.length()
  }
  if filled <= 0 {
    return 0.0
  }
  let values : Array[Double] = []
  for i in 0..<filled {
    values.push(self.recent[i])
  }
  values.sort()
  let idx = (filled.to_double() * 0.99).to_int()
  let clamped = if idx >= filled { filled - 1 } else { idx }
  values[clamped]
}

///|
/// Cap on `limit`, so one request cannot ask the server to materialize an
/// entire index.
const MAX_LIMIT : Int32 = 1000

///|
async fn main {
  let argv = @env.args()
  let mut addr_text = "127.0.0.1:7700"
  let mut snapshot : String? = None
  let mut assets_dir : String? = None
  let mut schema_text = "title:6,keywords:3,desc:1,deps:1.5"
  let mut shards_text = ""
  let mut pool_per_shard : Int32 = 200
  let mut shard_port : String? = None
  let mut shard_mode_text = "ring"
  let mut vnodes : Int32 = RING_VNODES
  let mut i = 1
  while i < argv.length() {
    let a = argv[i]
    if a == "--addr" && i + 1 < argv.length() {
      addr_text = argv[i + 1]
      i += 2
    } else if a == "--index" && i + 1 < argv.length() {
      snapshot = Some(argv[i + 1])
      i += 2
    } else if a == "--assets" && i + 1 < argv.length() {
      assets_dir = Some(argv[i + 1])
      i += 2
    } else if a == "--schema" && i + 1 < argv.length() {
      schema_text = argv[i + 1]
      i += 2
    } else if a == "--shards" && i + 1 < argv.length() {
      shards_text = argv[i + 1]
      i += 2
    } else if a == "--pool" && i + 1 < argv.length() {
      pool_per_shard = @string.parse_int(argv[i + 1]) catch { _ => 200 }
      i += 2
    } else if a == "--shard-port" && i + 1 < argv.length() {
      shard_port = Some(argv[i + 1])
      i += 2
    } else if a == "--shard-mode" && i + 1 < argv.length() {
      shard_mode_text = argv[i + 1]
      i += 2
    } else if a == "--vnodes" && i + 1 < argv.length() {
      vnodes = @string.parse_int(argv[i + 1]) catch { _ => RING_VNODES }
      i += 2
    } else if a == "--help" {
      println(
        "moonseek-server [--addr host:port] [--index snap.msk] [--assets dir] [--schema name:w,...] [--shards h:p[|r],...] [--pool N] [--shard-port host:port] [--shard-mode ring|modulo] [--vnodes N]",
      )
      return ()
    } else {
      println("unknown argument: \{a}")
      return ()
    }
  }
  let schema = match parse_schema(schema_text) {
    Some(s) => s
    None => {
      println("bad --schema: \{schema_text}")
      return ()
    }
  }
  let state = ServerState::new(schema)
  match snapshot {
    Some(path) => {
      let file = @fs.read_file(path) catch {
        e => {
          println("cannot read \{path}: \{e}")
          return ()
        }
      }
      let loaded = file.binary()
      let index = @moonseek.Index::from_bytes(loaded) catch {
        e => {
          println("cannot decode \{path}: \{e}")
          return ()
        }
      }
      let docs = index.doc_count()
      state.index = index
      println("loaded \{docs} documents from \{path}")
    }
    None => ()
  }
  // A coordinator owns no documents: it holds a shard list and fans out. Both
  // roles run the same binary, so this is the only switch between them.
  if !shards_text.is_empty() {
    let mode = match parse_shard_mode(shard_mode_text) {
      Some(m) => m
      None => {
        println("bad --shard-mode \{shard_mode_text}: expected ring or modulo")
        return ()
      }
    }
    state.cluster = parse_shards(shards_text)
    state.pool_per_shard = pool_per_shard
    state.shard_mode = mode
    state.vnodes = vnodes
    state.ring = build_ring(state.cluster.length(), vnodes~)
    println(
      "coordinating " +
      state.cluster.length().to_string() +
      " shard group(s), placement " +
      (if mode is Ring { "ring" } else { "modulo" }) +
      ", " +
      state.ring.points.length().to_string() +
      " ring points",
    )
  }
  let assets : String? = assets_dir
  let addr = @socket.Addr::parse(addr_text) catch {
    e => {
      println("bad address \{addr_text}: \{e}")
      return ()
    }
  }
  let server = @http.Server::Server(addr)
  println("moonseek-server listening on http://\{addr_text}")
  match assets {
    Some(d) => println("serving console from \{d}")
    None => ()
  }
  match shard_port {
    Some(port) => {
      // The shard listener runs alongside the HTTP server: one process can be a
      // shard for a coordinator and a search API at the same time, which is how
      // the cluster benchmark starts N shards without N binaries.
      let shard_addr = @socket.Addr::parse(port) catch {
        e => {
          println("bad --shard-port " + port + ": " + e.to_string())
          return ()
        }
      }
      println("shard listener on tcp://" + port)
      @async.with_task_group(async fn(group) {
        let _ = group.spawn(async fn() { run_shard_listener(state, shard_addr) })
        server.run_forever(async fn(req, reader, conn) {
          handle(state, assets, req, reader, conn)
        })
      })
    }
    None =>
      server.run_forever(async fn(req, reader, conn) {
        handle(state, assets, req, reader, conn)
      })
  }
}

///|
/// The shard protocol: one JSON object per connection, one JSON answer back,
/// then close. Deliberately tiny — the coordinator needs exactly four
/// operations, and a larger protocol is a larger thing to get wrong.
async fn run_shard_listener(state : ServerState, addr : @socket.Addr) -> Unit {
  let listener = @socket.TcpServer(addr)
  listener.run_forever(async fn(sock, _peer) {
    // Length-prefixed frames in both directions. Reading to EOF would deadlock
    // against a client that sends a request and then waits for the answer.
    let header = sock.read_exactly(4) catch { _ => return () }
    let length = unframe_length(header)
    if length <= 0 {
      return ()
    }
    let body = sock.read_exactly(length) catch { _ => return () }
    let text = @utf8.decode(body) catch { _ => return () }
    let answer = shard_handle(state, text.trim().to_owned())
    sock.write(frame(@utf8.encode(answer))) catch {
      _ => ()
    }
  })
}

///|
/// Parse the optional `stats` block of a shard search request:
/// `{"n": 3000, "df": {"f\u0000t": 12}, "avgdl": {"f": 41.2}}`.
fn stats_from_request(obj : Map[String, Json]) -> @moonseek.ExternalStats? {
  let stats_json = match obj.get("stats") {
    Some(Object(m)) => m
    _ => return None
  }
  let n = match stats_json.get("n") {
    Some(Number(v, ..)) => v.to_int()
    _ => 0
  }
  let df : Array[((String, String), Int32)] = []
  match stats_json.get("df") {
    Some(Object(pairs)) =>
      for (key, value) in pairs.iter() {
        match value {
          Number(v, ..) => df.push((split_stat_key(key), v.to_int()))
          _ => ()
        }
      }
    _ => ()
  }
  let avgdl : Array[(String, Double)] = []
  match stats_json.get("avgdl") {
    Some(Object(pairs)) =>
      for (field, value) in pairs.iter() {
        match value {
          Number(v, ..) => avgdl.push((field, v))
          _ => ()
        }
      }
    _ => ()
  }
  Some(@moonseek.ExternalStats::new(n, df~, avgdl~))
}

///|
/// `"field\u0000term"` back into a pair. The NUL separator is unambiguous
/// because neither a field name nor an analyzed term can contain one.
fn split_stat_key(key : String) -> (String, String) {
  match key.find("\u{0}") {
    Some(idx) => (key[:idx].to_owned(), key[idx + 1:].to_owned())
    None => (key, "")
  }
}

///|
/// Answer one shard request.
fn shard_handle(state : ServerState, request : String) -> String {
  let json = match parse_json_or_none(request) {
    Some(j) => j
    None => return "{\"error\":\"bad json\"}"
  }
  let obj = match json {
    Object(o) => o
    _ => return "{\"error\":\"not an object\"}"
  }
  let op = match obj.get("op") {
    Some(String(s)) => s
    _ => return "{\"error\":\"missing op\"}"
  }
  match op {
    "ping" => "{\"ok\":true}"
    "index" => {
      let body = match obj.get("body") {
        Some(String(s)) => s
        _ => return "{\"error\":\"missing body\"}"
      }
      let text = apply_document(state, body) catch {
        e => return error_json("bad_request", e.to_string())
      }
      state.indexed_docs += 1
      text
    }
    "bulk" => {
      // A coordinator groups a bulk write by owning shard, so a shard gets one
      // request carrying only the documents it owns, not one request per
      // document.
      let body = match obj.get("body") {
        Some(String(s)) => s
        _ => return "{\"error\":\"missing body\"}"
      }
      index_bulk(state, body)
    }
    "delete" => {
      let id = match obj.get("id") {
        Some(String(s)) => s
        _ => return "{\"error\":\"missing id\"}"
      }
      let deleted = state.index.delete(id)
      if deleted {
        state.deleted_docs += 1
      }
      let fields : Map[String, Json] = Map([])
      fields["ok"] = @json.to_json(true)
      fields["deleted"] = @json.to_json(deleted)
      fields["id"] = @json.to_json(id)
      Json::object(fields).stringify()
    }
    "search" => {
      let query = match obj.get("query") {
        Some(String(s)) => s
        _ => ""
      }
      let limit = match obj.get("limit") {
        Some(Number(n, ..)) => n.to_int()
        _ => 10
      }
      // A `stats` block means the coordinator wants globally consistent
      // scoring: install the corpus-wide numbers for this one query, then take
      // them straight back out. Leaving them installed would mis-score a later
      // local query, which is the kind of bug that only shows up under load.
      let filters = requested_filters(obj)
      match stats_from_request(obj) {
        Some(stats) => {
          state.index.set_external_stats(Some(stats))
          defer state.index.set_external_stats(None)
          shard_search(state, query, limit, filters)
        }
        None => shard_search(state, query, limit, filters)
      }
    }
    "stats" =>
      // `df` and field lengths for the terms the coordinator named, so a
      // two-phase query carries only the statistics it will read.
      shard_stats(state, requested_terms(obj))
    "agg" =>
      // Corpus-wide aggregation, computed on this shard's slice. The
      // coordinator merges the replies; see cluster_aggregate for why terms can
      // be summed, stats have to be recombined rather than averaged, and
      // percentiles need the raw values shipped.
      shard_aggregate(state, obj)
    "ids" =>
      // Every live document id this shard holds. The coordinator uses these to
      // plan a rebalance over the real keys rather than a synthetic sample.
      shard_ids(state)
    _ => "{\"error\":\"unknown op\"}"
  }
}

///|
/// Aggregations for this shard's slice of the corpus.
///
/// The request carries `specs` (the same JSON shape `POST /search` accepts),
/// `filters`, and `values` — the numeric fields whose percentiles cannot be
/// merged from summaries and therefore have to travel as raw values.
///
/// A spec that fails to parse is *dropped*, so the reply has fewer results than
/// the request had specs; the coordinator checks that count and treats a short
/// reply as a failed shard rather than merging it at the wrong offsets.
fn shard_aggregate(state : ServerState, obj : Map[String, Json]) -> String {
  let query = match obj.get("query") {
    Some(String(s)) => s
    _ => ""
  }
  let specs : Array[@moonseek.AggSpec] = []
  match obj.get("specs") {
    Some(Array(items)) =>
      for item in items {
        match parse_agg_json(item) {
          Some(spec) => specs.push(spec)
          None => ()
        }
      }
    _ => ()
  }
  let filters = requested_filters(obj)
  let results = state.index.aggregate(query, specs, filters~) catch {
    e => return error_json("bad_request", e.to_string())
  }
  let rendered : Array[String] = []
  for r in results {
    rendered.push(r.to_json().stringify())
  }
  let values : Map[String, Json] = Map([])
  match obj.get("values") {
    Some(Array(items)) =>
      for item in items {
        if item is String(field) {
          let nums = state.index.agg_values(query, field, filters~) catch {
            _ => []
          }
          let arr : Array[Json] = []
          for v in nums {
            arr.push(@json.to_json(v))
          }
          values[field] = Json::array(arr)
        }
      }
    _ => ()
  }
  "{\"results\":[" +
  rendered.join(",") +
  "],\"values\":" +
  Json::object(values).stringify() +
  "}"
}

///|
/// The live document ids in this shard, as `{"ids":[...],"docs":N}`.
///
/// Walks the index's slots rather than any per-field structure: a document with
/// empty text in every field still has an id and still has to be moved by a
/// rebalance plan, so it must be counted here.
fn shard_ids(state : ServerState) -> String {
  let items : Array[String] = []
  for id in local_ids(state) {
    items.push(@json.to_json(id).stringify())
  }
  "{\"ids\":[" +
  items.join(",") +
  "],\"docs\":" +
  state.index.doc_count().to_string() +
  "}"
}

///|
/// Every live document id in this process's own index, in slot order.
fn local_ids(state : ServerState) -> Array[String] {
  let ids : Array[String] = []
  for slot in 0..<state.index.slot_count() {
    if state.index.is_deleted(slot) {
      continue
    }
    match state.index.doc_id(slot) {
      Some(id) => ids.push(id)
      None => ()
    }
  }
  ids
}

///|
fn shard_mode_name(mode : ShardMode) -> String {
  match mode {
    Ring => "ring"
    Modulo => "modulo"
  }
}

///|
/// A rebalance plan as JSON, with the movement fraction already computed: the
/// raw counts are not comparable at a glance, and the fraction is the number
/// that decides whether a grow-in-place is worth it.
fn rebalance_to_json(plan : Rebalance) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["moved"] = @json.to_json(plan.moved)
  fields["total"] = @json.to_json(plan.total)
  let pct = if plan.total == 0 {
    0.0
  } else {
    plan.moved.to_double() / plan.total.to_double() * 100.0
  }
  fields["moved_pct"] = @json.to_json(pct)
  let before : Array[Json] = []
  for count in plan.before {
    before.push(@json.to_json(count))
  }
  let after : Array[Json] = []
  for count in plan.after {
    after.push(@json.to_json(count))
  }
  fields["before"] = Json::array(before)
  fields["after"] = Json::array(after)
  Json::object(fields)
}

///|
/// A write acknowledgement as JSON.
///
/// `ok` means *every* member applied it, which is the only reading of "ok" a
/// client can act on: a write acknowledged by one member of three is not
/// durable, and reporting it as a success is how a cluster loses data quietly.
/// `acked`/`members` carry the partial case, with the addresses that did not
/// answer named.
fn write_reply(
  state : ServerState,
  id : String,
  group_index : Int32,
  ack : WriteAck,
) -> String {
  let fields : Map[String, Json] = Map([])
  fields["ok"] = @json.to_json(ack.failed.length() == 0)
  fields["id"] = @json.to_json(id)
  fields["shard"] = @json.to_json(group_index)
  fields["acked"] = @json.to_json(ack.acked)
  fields["members"] = @json.to_json(ack.members)
  if group_index >= 0 && group_index < state.cluster.length() {
    fields["primary"] = @json.to_json(state.cluster[group_index].primary)
  }
  if ack.failed.length() > 0 {
    let arr : Array[Json] = []
    for address in ack.failed {
      arr.push(@json.to_json(address))
    }
    fields["failed_addresses"] = Json::array(arr)
  }
  Json::object(fields).stringify()
}

///|
/// Route one document from a coordinator to the group that owns it, replicating
/// it to every member. The reply says how many members applied it.
async fn coordinator_index(state : ServerState, body : String) -> String {
  let id = match doc_id_of(body) {
    Some(id) => id
    None => raise Failure::Failure("document needs a string id")
  }
  let group_index = state.group_for(id)
  let request = "{\"op\":\"index\",\"body\":" +
    @json.to_json(body).stringify() +
    "}"
  let ack = write_group(state.cluster[group_index], request)
  // The coordinator counts what it accepted, not what it applied: it applies
  // nothing itself.
  state.indexed_docs += 1
  write_reply(state, id, group_index, ack)
}

///|
/// Route a delete from a coordinator to the owning group, replicating it.
async fn coordinator_delete(state : ServerState, id : String) -> String {
  let group_index = state.group_for(id)
  let request = "{\"op\":\"delete\",\"id\":" +
    @json.to_json(id).stringify() +
    "}"
  let ack = write_group(state.cluster[group_index], request)
  write_reply(state, id, group_index, ack)
}

///|
/// `POST /index/bulk` on a coordinator: split the batch by owning shard and
/// send each shard one request carrying only its documents.
///
/// One request per shard rather than one per document is the difference between
/// a bulk load that is one round trip per shard and one that is one round trip
/// per document. It is also why a batch is grouped here rather than forwarded
/// whole: a shard that received the entire batch would index documents it does
/// not own, and then two shards would answer for the same document.
async fn coordinator_bulk(state : ServerState, body : String) -> String {
  let started = @env.now()
  let per_shard : Array[Array[String]] = []
  for _ in 0..<state.cluster.length() {
    per_shard.push([])
  }
  let mut malformed = 0
  for line in body.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed.is_empty() {
      continue
    }
    match doc_id_of(trimmed) {
      Some(id) => per_shard[state.group_for(id)].push(trimmed)
      None => malformed = malformed + 1
    }
  }
  let acks : Array[WriteAck?] = Array::make(state.cluster.length(), None)
  @async.with_task_group(fn(tasks) {
    for i in 0..<state.cluster.length() {
      if per_shard[i].length() == 0 {
        continue
      }
      let index = i
      let request = "{\"op\":\"bulk\",\"body\":" +
        @json.to_json(per_shard[index].join("\n")).stringify() +
        "}"
      let _ = tasks.spawn(
        async fn() {
          acks[index] = Some(write_group(state.cluster[index], request))
        },
        allow_failure=true,
      )
    }
  })
  let mut indexed = 0
  let mut failed = malformed
  let mut members_total = 0
  let mut members_ok = 0
  let unreplicated : Array[String] = []
  for i in 0..<state.cluster.length() {
    match acks[i] {
      Some(ack) => {
        members_total += ack.members
        members_ok += ack.acked
        for address in ack.failed {
          unreplicated.push(address)
        }
        // Per-document failures come from the shard's own count, so a batch
        // with one bad document is reported as one failure rather than as a
        // failed shard.
        failed += bulk_failed_of(ack.reply)
        if ack.acked > 0 {
          indexed += per_shard[i].length() - bulk_failed_of(ack.reply)
        }
      }
      None => ()
    }
  }
  state.indexed_docs += indexed.to_int64()
  let fields : Map[String, Json] = Map([])
  fields["indexed"] = @json.to_json(indexed)
  fields["failed"] = @json.to_json(failed)
  fields["shards"] = @json.to_json(state.cluster.length())
  fields["members_ok"] = @json.to_json(members_ok)
  fields["members"] = @json.to_json(members_total)
  fields["took_ms"] = @json.to_json((@env.now() - started).to_double())
  if unreplicated.length() > 0 {
    let arr : Array[Json] = []
    for address in unreplicated {
      arr.push(@json.to_json(address))
    }
    fields["failed_addresses"] = Json::array(arr)
  }
  Json::object(fields).stringify()
}

///|
/// The `failed` count out of a shard's bulk reply, or 0 when it cannot be read.
/// A shard that reports a different shape is not treated as having failed every
/// document it was sent.
fn bulk_failed_of(reply : String) -> Int32 {
  match parse_json_or_none(reply) {
    Some(Object(fields)) =>
      match fields.get("failed") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// The `[["term","field"], ...]` list a `stats` request carries.
fn requested_terms(obj : Map[String, Json]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  match obj.get("terms") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Array(pair) if pair.length() == 2 =>
            match (pair[0], pair[1]) {
              (String(term), String(field)) => out.push((field, term))
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// The `[["field",["v1","v2"]], …]` filter list a search or aggregation request
/// carries. A pair with no readable values is dropped rather than kept as an
/// empty allow-list, which would match nothing and silently empty the answer.
fn requested_filters(obj : Map[String, Json]) -> Array[(String, Array[String])] {
  let out : Array[(String, Array[String])] = []
  match obj.get("filters") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Array(pair) if pair.length() == 2 =>
            match (pair[0], pair[1]) {
              (String(field), Array(values)) => {
                let vals : Array[String] = []
                for v in values {
                  if v is String(sv) {
                    vals.push(sv)
                  }
                }
                if !vals.is_empty() {
                  out.push((field, vals))
                }
              }
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Plain (field, values) pairs into the engine's filter type: values within one
/// field are "either", different fields are "and".
fn to_facet_filters(
  pairs : Array[(String, Array[String])],
) -> Array[@moonseek.FacetFilter] {
  let filters : Array[@moonseek.FacetFilter] = []
  for (field, values) in pairs {
    for v in values {
      push_filter(filters, field, v)
    }
  }
  filters
}

///|
fn shard_search(
  state : ServerState,
  query : String,
  limit : Int32,
  filters : Array[(String, Array[String])],
) -> String {
  // `search_faceted` rather than `search`: the filters have to be applied here,
  // on the node that holds the documents — a coordinator that applied them
  // locally would be filtering an index it does not have. This call also
  // returns the filtered match count, where a separate `count` call would count
  // the unfiltered matches and report a total larger than the hits it returned.
  let options : @moonseek.SearchOptions = {
    limit,
    offset: 0,
    filters: to_facet_filters(filters),
    facet_fields: [],
  }
  let result = state.index.search_faceted(query, options~) catch {
    e => return error_json("bad_request", e.to_string())
  }
  let items : Array[String] = []
  for h in result.hits {
    items.push(
      "[" + @json.to_json(h.id).stringify() + "," + h.score.to_string() + "]",
    )
  }
  "{\"hits\":[" +
  items.join(",") +
  "],\"docs\":" +
  state.index.doc_count().to_string() +
  ",\"total\":" +
  result.total.to_string() +
  "}"
}

///|
/// Corpus statistics for the named (field, term) pairs, plus per-field length
/// sums and live counts so the coordinator can compute a global `avgdl`.
fn shard_stats(state : ServerState, terms : Array[(String, String)]) -> String {
  let entries : Array[String] = []
  let fields_seen : Array[String] = []
  for (field, term) in terms {
    let key = stat_key(field, term)
    entries.push(
      @json.to_json(key).stringify() +
      ":" +
      state.index.doc_freq(field, term).to_string(),
    )
    if !fields_seen.contains(field) {
      fields_seen.push(field)
    }
  }
  let lengths : Array[String] = []
  let counts : Array[String] = []
  for field in fields_seen {
    // O(1) from the index's own per-field statistics. The previous version
    // re-analyzed every document's text to recount tokens, which turned a
    // statistics round into a full re-index and cost ~45 ms per query.
    lengths.push(
      @json.to_json(field).stringify() +
      ":" +
      state.index.field_length_total(field).to_string(),
    )
    counts.push(
      @json.to_json(field).stringify() +
      ":" +
      state.index.field_doc_count(field).to_string(),
    )
  }
  "{\"docs\":" +
  state.index.doc_count().to_string() +
  ",\"df\":{" +
  entries.join(",") +
  "},\"field_lengths\":{" +
  lengths.join(",") +
  "},\"field_counts\":{" +
  counts.join(",") +
  "}}"
}

///|
/// Parse `name:weight,name:weight` into a schema.
fn parse_schema(text : String) -> Array[@moonseek.FieldSchema]? {
  let out : Array[@moonseek.FieldSchema] = []
  for part in text.split(",") {
    let trimmed = part.trim()
    if trimmed.is_empty() {
      continue
    }
    match trimmed.find(":") {
      Some(idx) => {
        let name = trimmed[:idx].to_owned()
        let weight = @string.parse_double(trimmed[idx + 1:].to_owned()) catch {
          _ => return None
        }
        out.push({ name, weight, })
      }
      None => return None
    }
  }
  if out.is_empty() {
    None
  } else {
    Some(out)
  }
}

///|
/// Route one request. Every handler answers; nothing is allowed to fall through
/// without writing a response.
async fn handle(
  state : ServerState,
  assets : String?,
  req : @http.Request,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let path = req.path
  let http_method = req.meth
  let (route, query_text) = match path.find("?") {
    Some(idx) => (path[:idx].to_owned(), path[idx + 1:].to_owned())
    None => (path, "")
  }
  let params = parse_query_string(query_text)
  match route {
    "/healthz" => {
      respond_json(conn, 200, "OK", health_json(state))
      return ()
    }
    "/_stats" => {
      respond_json(conn, 200, "OK", stats_json(state))
      return ()
    }
    "/search" => {
      let started = @env.now()
      if http_method is Post {
        let body = read_body(reader)
        let parsed = @json.parse(body) catch {
          e =>
            return respond_json(
              conn,
              400,
              "Bad Request",
              error_json("bad_request", "bad json: " + @debug.to_string(e)),
            )
        }
        let text = do_search(state, params, Some(parsed)) catch {
          e =>
            return respond_json(
              conn,
              400,
              "Bad Request",
              error_json("bad_request", e.to_string()),
            )
        }
        state.observe_query((@env.now() - started).to_double())
        respond_json(conn, 200, "OK", text)
        return ()
      }
      let text = do_search(state, params, None) catch {
        e =>
          return respond_json(
            conn,
            400,
            "Bad Request",
            error_json("bad_request", e.to_string()),
          )
      }
      state.observe_query((@env.now() - started).to_double())
      respond_json(conn, 200, "OK", text)
      return ()
    }
    "/_ring" => {
      // What the coordinator's placement actually is: the rule, the ring size,
      // and how the ring's points split across shards. Point counts are not
      // document counts, but a shard holding two thirds of the *points* is the
      // first sign the hash is skewed.
      let fields : Map[String, Json] = Map([])
      let is_coordinator = !state.cluster.is_empty()
      fields["role"] = @json.to_json(
        if is_coordinator {
          "coordinator"
        } else {
          "node"
        },
      )
      fields["shards"] = @json.to_json(state.cluster.length())
      fields["mode"] = @json.to_json(shard_mode_name(state.shard_mode))
      fields["vnodes"] = @json.to_json(state.vnodes)
      fields["ring_points"] = @json.to_json(state.ring.points.length())
      let counts = Array::make(state.cluster.length(), 0)
      for point in state.ring.points {
        if point.1 >= 0 && point.1 < counts.length() {
          counts[point.1] = counts[point.1] + 1
        }
      }
      let per_shard : Array[Json] = []
      let primaries : Array[Json] = []
      for i in 0..<counts.length() {
        per_shard.push(@json.to_json(counts[i]))
        let entry : Map[String, Json] = Map([])
        entry["primary"] = @json.to_json(state.cluster[i].primary)
        entry["points"] = @json.to_json(counts[i])
        primaries.push(Json::object(entry))
      }
      fields["points_per_shard"] = Json::array(per_shard)
      fields["groups"] = Json::array(primaries)
      respond_json(conn, 200, "OK", Json::object(fields).stringify())
      return ()
    }
    "/_placement" => {
      // Which shard group owns one document id. The client-visible half of the
      // placement rule: a client can compute the same answer itself, and this
      // is how that is checked rather than assumed.
      let id = get_param(params, "id")
      let owner = state.group_for(id)
      let fields : Map[String, Json] = Map([])
      fields["id"] = @json.to_json(id)
      fields["shard"] = @json.to_json(owner)
      fields["mode"] = @json.to_json(shard_mode_name(state.shard_mode))
      fields["local"] = @json.to_json(owner < 0)
      if owner >= 0 && owner < state.cluster.length() {
        fields["primary"] = @json.to_json(state.cluster[owner].primary)
      }
      respond_json(conn, 200, "OK", Json::object(fields).stringify())
      return ()
    }
    "/_plan" => {
      // A rebalancing plan: how many documents would move if the cluster grew
      // (or shrank) to `shards` groups, under both placement rules. Answers
      // from the real document ids, gathered from the shards, not from a
      // synthetic sample.
      let target = int_param(params, "shards", 0)
      if target <= 0 || target > 1024 {
        return respond_json(
          conn,
          400,
          "Bad Request",
          error_json("bad_request", "?shards=N is required (1..1024)"),
        )
      }
      let (ids, failed) = if state.cluster.is_empty() {
        (local_ids(state), Array::make(0, ""))
      } else {
        let config : ClusterConfig = {
          shards: state.cluster,
          pool_per_shard: state.pool_per_shard,
          timeout_ms: 4000,
        }
        cluster_all_ids(config)
      }
      let from_shards = if state.cluster.is_empty() {
        1
      } else {
        state.cluster.length()
      }
      let ring = rebalance_plan(ids, from_shards, target, Ring)
      let modulo = rebalance_plan(ids, from_shards, target, Modulo)
      let fields : Map[String, Json] = Map([])
      fields["ids"] = @json.to_json(ids.length())
      fields["from_shards"] = @json.to_json(from_shards)
      fields["to_shards"] = @json.to_json(target)
      // Which rule the coordinator is actually using, so a client is not left
      // guessing which of the two numbers below is in force.
      fields["active_mode"] = @json.to_json(shard_mode_name(state.shard_mode))
      fields["ring"] = rebalance_to_json(ring)
      fields["modulo"] = rebalance_to_json(modulo)
      if failed.length() > 0 {
        let addrs : Array[Json] = []
        for address in failed {
          addrs.push(@json.to_json(address))
        }
        fields["failed_addresses"] = Json::array(addrs)
      }
      respond_json(conn, 200, "OK", Json::object(fields).stringify())
      return ()
    }
    "/_dfs" => {
      // Diagnostics for the two-phase path: what the coordinator gathered.
      if state.cluster.is_empty() {
        return respond_json(
          conn,
          400,
          "Bad Request",
          error_json("bad_request", "not a coordinator"),
        )
      }
      let q = get_param(params, "q")
      let config : ClusterConfig = {
        shards: state.cluster,
        pool_per_shard: state.pool_per_shard,
        timeout_ms: 2000,
      }
      let body = match query_terms_local(state, q) {
        Some(terms) => {
          let gathered = cluster_gather_stats(config, terms)
          stats_to_json(gathered)
        }
        None => error_json("bad_request", "query terms are shard-dependent")
      }
      respond_json(conn, 200, "OK", body)
      return ()
    }
    "/suggest" => {
      let q = get_param(params, "q")
      let fields : Map[String, Json] = Map([])
      fields["suggestion"] = @json.to_json(state.index.suggest(q).unwrap_or(""))
      let fuzzy : Array[Json] = []
      for m in state.index.fuzzy_terms(q, max_distance=2) {
        fuzzy.push(
          Json::array([@json.to_json(m.term), @json.to_json(m.distance)]),
        )
      }
      fields["fuzzy"] = Json::array(fuzzy)
      respond_json(conn, 200, "OK", Json::object(fields).stringify())
      return ()
    }
    "/terms" => {
      respond_json(conn, 200, "OK", terms_json(state, params))
      return ()
    }
    "/explain" => {
      let id = get_param(params, "id")
      let q = get_param(params, "q")
      // A malformed query is the client's fault (400); a well-formed query that
      // matches nothing is a missing document (404). Parse first so the two are
      // distinguished instead of collapsed into one error.
      let parsed = @moonseek.parse_query(
        q,
        analyzer=state.index.analyzer(),
        fields=schema_names(state),
      ) catch {
        e =>
          return respond_json(
            conn,
            400,
            "Bad Request",
            error_json("bad_request", e.to_string()),
          )
      }
      let _ = parsed
      // With a query that parsed, explain cannot fail; the catch keeps the
      // handler's signature free of raise.
      let explained : @moonseek.Explanation? = state.index.explain(q, id) catch {
        _ => None
      }
      match explained {
        Some(e) => respond_json(conn, 200, "OK", e.to_json().stringify())
        None =>
          respond_json(
            conn,
            404,
            "Not Found",
            error_json("not_found", "no such document or no match: " + id),
          )
      }
      return ()
    }
    "/index" => {
      if http_method is Post {
        let body = read_body(reader)
        // A coordinator owns no documents: it routes the write to the group
        // that owns the id and replicates it to every member of that group.
        if !state.cluster.is_empty() {
          let text = coordinator_index(state, body) catch {
            e =>
              return respond_json(
                conn,
                400,
                "Bad Request",
                error_json("bad_request", e.to_string()),
              )
          }
          respond_json(conn, 202, "Accepted", text)
          return ()
        }
        let text = apply_document(state, body) catch {
          e =>
            return respond_json(
              conn,
              400,
              "Bad Request",
              error_json("bad_request", e.to_string()),
            )
        }
        state.indexed_docs += 1
        respond_json(conn, 202, "Accepted", text)
        return ()
      }
      if http_method is Delete {
        let id = get_param(params, "id")
        if !state.cluster.is_empty() {
          // The delete has to reach the group that owns the id, or the
          // coordinator would report a deletion that never happened while the
          // document stayed searchable.
          return respond_json(conn, 200, "OK", coordinator_delete(state, id))
        }
        let deleted = state.index.delete(id)
        if deleted {
          state.deleted_docs += 1
        }
        let fields : Map[String, Json] = Map([])
        fields["deleted"] = @json.to_json(deleted)
        respond_json(conn, 200, "OK", Json::object(fields).stringify())
        return ()
      }
    }
    "/index/bulk" =>
      if http_method is Post {
        let body = read_body(reader)
        if !state.cluster.is_empty() {
          return respond_json(conn, 200, "OK", coordinator_bulk(state, body))
        }
        respond_json(conn, 200, "OK", index_bulk(state, body))
        return ()
      }
    _ => ()
  }
  if serve_asset(assets, route, conn) {
    return ()
  }
  respond_json(
    conn,
    404,
    "Not Found",
    error_json("not_found", "no route for " + route),
  )
}

///|
/// The field a snippet is taken from when the client does not name one.
fn prose_field(state : ServerState) -> String {
  let mut best = ""
  let mut best_weight = 1.0e300
  for f in state.schema {
    if f.name == "body" {
      return "body"
    }
    if f.weight < best_weight {
      best_weight = f.weight
      best = f.name
    }
  }
  best
}

///|
/// Declared field names, for query parsing.
fn schema_names(state : ServerState) -> Array[String] {
  let out : Array[String] = []
  for f in state.schema {
    out.push(f.name)
  }
  out
}

///|
/// Serve a file from the console directory. Returns true when it answered.
async fn serve_asset(
  assets : String?,
  route : String,
  conn : @http.ServerConnection,
) -> Bool {
  let dir = match assets {
    Some(d) => d
    None => return false
  }
  let relative = if route == "/" || route.is_empty() {
    "index.html"
  } else if route.has_prefix("/") {
    route[1:].to_owned()
  } else {
    route
  }
  // Path-traversal guard: the request must not escape the asset directory.
  if relative.contains("..") {
    return false
  }
  let full = dir + "/" + relative
  let file = @fs.read_file(full) catch { _ => return false }
  let text = file.text() catch { _ => return false }
  let content_type = if relative.has_suffix(".html") {
    "text/html; charset=utf-8"
  } else if relative.has_suffix(".js") {
    "text/javascript; charset=utf-8"
  } else if relative.has_suffix(".css") {
    "text/css; charset=utf-8"
  } else if relative.has_suffix(".json") {
    "application/json; charset=utf-8"
  } else {
    "application/octet-stream"
  }
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("Content-Type")] = content_type
  headers[@http.CaseInsensitiveString("Access-Control-Allow-Origin")] = "*"
  conn.send_response(200, "OK", extra_headers=headers)
  conn.write_string(text)
  true
}

///|
/// Read a request body fully.
async fn read_body(reader : &@io.Reader) -> String {
  let data = reader.read_all() catch { _ => return "" }
  data.text() catch {
    _ => ""
  }
}

///|
async fn respond_json(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  body : String,
) -> Unit {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("Content-Type")] = "application/json; charset=utf-8"
  headers[@http.CaseInsensitiveString("Access-Control-Allow-Origin")] = "*"
  headers[@http.CaseInsensitiveString("Cache-Control")] = "no-store"
  conn.send_response(code, reason, extra_headers=headers)
  conn.write_string(body)
}

///|
fn error_json(code : String, msg : String) -> String {
  let fields : Map[String, Json] = Map([])
  fields["error"] = @json.to_json(msg)
  fields["code"] = @json.to_json(code)
  Json::object(fields).stringify()
}

///|
fn health_json(state : ServerState) -> String {
  let fields : Map[String, Json] = Map([])
  fields["status"] = @json.to_json("ok")
  fields["version"] = @json.to_json("0.7.0")
  fields["uptime_ms"] = @json.to_json(
    (@env.now() - state.started_ms).to_int().to_double(),
  )
  Json::object(fields).stringify()
}

///|
fn stats_json(state : ServerState) -> String {
  let index = state.index
  let fields : Map[String, Json] = Map([])
  fields["docs"] = @json.to_json(index.doc_count())
  fields["terms"] = @json.to_json(index.term_count())
  let names : Array[Json] = []
  for f in state.schema {
    names.push(@json.to_json(f.name))
  }
  fields["fields"] = Json::array(names)
  fields["snapshot_bytes"] = @json.to_json(index.to_bytes().length())
  fields["queries_served"] = @json.to_json(state.queries_served.to_int())
  fields["indexed_docs"] = @json.to_json(state.indexed_docs.to_int())
  fields["deleted_docs"] = @json.to_json(state.deleted_docs.to_int())
  fields["avg_query_ms"] = @json.to_json(state.avg_query_ms())
  fields["p99_query_ms"] = @json.to_json(state.p99_query_ms())
  fields["max_query_ms"] = @json.to_json(state.max_query_ms)
  if !state.cluster.is_empty() {
    // A coordinator owns no documents, so its own counters are all zero; the
    // shard list is the only honest thing it can report about the corpus.
    let groups : Array[Json] = []
    for group in state.cluster {
      let replicas : Array[Json] = []
      for r in group.replicas {
        replicas.push(@json.to_json(r))
      }
      let entry : Map[String, Json] = Map([])
      entry["primary"] = @json.to_json(group.primary)
      entry["replicas"] = Json::array(replicas)
      groups.push(Json::object(entry))
    }
    fields["shards"] = Json::array(groups)
    fields["role"] = @json.to_json("coordinator")
  } else {
    fields["role"] = @json.to_json("node")
  }
  Json::object(fields).stringify()
}

///|
fn terms_json(state : ServerState, params : Array[(String, String)]) -> String {
  let requested = get_param(params, "field")
  let field = if requested.is_empty() {
    match state.schema.get(0) {
      Some(s) => s.name
      None => ""
    }
  } else {
    requested
  }
  let limit = int_param(params, "limit", 50)
  let items : Array[Json] = []
  let mut count = 0
  for term in state.index.terms_of(field) {
    if count >= limit {
      break
    }
    items.push(
      Json::array([
        @json.to_json(term),
        @json.to_json(state.index.doc_freq(field, term)),
      ]),
    )
    count += 1
  }
  let fields : Map[String, Json] = Map([])
  fields["terms"] = Json::array(items)
  Json::object(fields).stringify()
}

///|
/// Query string to (key, value) pairs, percent-decoded once.
fn parse_query_string(text : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  if text.is_empty() {
    return out
  }
  for pair in text.split("&") {
    if pair.is_empty() {
      continue
    }
    match pair.find("=") {
      Some(idx) =>
        out.push(
          (
            percent_decode(pair[:idx].to_owned()),
            percent_decode(pair[idx + 1:].to_owned()),
          ),
        )
      None => out.push((percent_decode(pair.to_owned()), ""))
    }
  }
  out
}

///|
/// Percent- and plus-decoding. Operates on bytes, so a multi-byte UTF-8
/// sequence encoded as `%E4%B8%AD` is reassembled before the string is built —
/// decoding per character would corrupt it.
fn percent_decode(text : String) -> String {
  if !text.contains("%") && !text.contains("+") {
    return text
  }
  let chars = text.to_array()
  let bytes : Array[Int32] = []
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '+' {
      bytes.push(32)
      i += 1
    } else if c == '%' && i + 2 < chars.length() {
      match (hex_value(chars[i + 1]), hex_value(chars[i + 2])) {
        (Some(h), Some(l)) => {
          bytes.push(h * 16 + l)
          i += 3
        }
        _ => {
          // A stray '%' is literal text, not an error worth failing a request
          // over.
          bytes.push(c.to_int())
          i += 1
        }
      }
    } else {
      let code = c.to_int()
      if code < 128 {
        bytes.push(code)
      } else {
        // Already-decoded non-ASCII: re-encode to UTF-8 bytes so the whole
        // buffer can be decoded once at the end.
        for b in @utf8.encode(c.to_string()).iter() {
          bytes.push(b.to_int())
        }
      }
      i += 1
    }
  }
  let out = @buffer.Buffer(size_hint=bytes.length())
  for b in bytes {
    out.write_byte(b.to_byte())
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
fn hex_value(c : Char) -> Int32? {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    Some(n - 48)
  } else if n >= 97 && n <= 102 {
    Some(n - 87)
  } else if n >= 65 && n <= 70 {
    Some(n - 55)
  } else {
    None
  }
}

///|
fn get_param(params : Array[(String, String)], key : String) -> String {
  let mut out = ""
  for (k, v) in params {
    if k == key {
      out = v
    }
  }
  out
}

///|
fn params_all(params : Array[(String, String)], key : String) -> Array[String] {
  let out : Array[String] = []
  for (k, v) in params {
    if k == key {
      out.push(v)
    }
  }
  out
}

///|
fn int_param(
  params : Array[(String, String)],
  key : String,
  fallback : Int32,
) -> Int32 {
  let text = get_param(params, key)
  if text.is_empty() {
    return fallback
  }
  @string.parse_int(text) catch {
    _ => fallback
  }
}

///|
fn double_param(
  params : Array[(String, String)],
  key : String,
  fallback : Double,
) -> Double {
  let text = get_param(params, key)
  if text.is_empty() {
    return fallback
  }
  @string.parse_double(text) catch {
    _ => fallback
  }
}

///|
fn bool_param(params : Array[(String, String)], key : String) -> Bool {
  let text = get_param(params, key)
  text == "true" || text == "1" || text == "yes"
}

///|
/// The search path: parameters in, JSON out.
///
/// The query string carries `q` and pagination; the optional JSON body adds
/// facets, aggregations, filters, sort and the vector query.
async fn do_search(
  state : ServerState,
  params : Array[(String, String)],
  body : Json?,
) -> String {
  let index = state.index
  let mut query = get_param(params, "q")
  let mut limit = int_param(params, "limit", 10)
  let mut offset = int_param(params, "offset", 0)
  let facet_fields : Array[String] = []
  // Default highlight field: the lowest-weighted declared field. Weighting a
  // field down is the schema's way of saying "this is the prose", so title/body
  // picks body and the registry schema's title/keywords/desc/deps picks desc.
  // Hardcoding "body" meant every hit on the registry came back with an empty
  // snippet.
  let mut highlight_field = prose_field(state)
  let snippet_chars = int_param(params, "snippet_chars", 160)
  let mut want_explain = bool_param(params, "explain")
  let filters : Array[@moonseek.FacetFilter] = []
  let aggs : Array[@moonseek.AggSpec] = []
  let knn_vector : Array[Double] = []
  let mut knn_field = ""
  let mut knn_k : Int32 = 100
  let mut fusion = @moonseek.Rrf
  // Query-string forms first; the body overrides where both are present.
  let facet_text = get_param(params, "facets")
  if !facet_text.is_empty() {
    for name in facet_text.split(",") {
      if !name.is_empty() {
        facet_fields.push(name.to_owned())
      }
    }
  }
  for raw in params_all(params, "filter") {
    match raw.find(":") {
      Some(idx) =>
        push_filter(filters, raw[:idx].to_owned(), raw[idx + 1:].to_owned())
      None => ()
    }
  }
  for raw in params_all(params, "agg") {
    match parse_agg_shorthand(raw) {
      Some(spec) => aggs.push(spec)
      None => ()
    }
  }
  match body {
    Some(Object(fields)) => {
      match fields.get("query") {
        Some(String(q)) => query = q
        _ => ()
      }
      match fields.get("limit") {
        Some(Number(n, ..)) => limit = n.to_int()
        _ => ()
      }
      match fields.get("offset") {
        Some(Number(n, ..)) => offset = n.to_int()
        _ => ()
      }
      match fields.get("facets") {
        Some(Array(items)) => {
          facet_fields.clear()
          for item in items {
            if item is String(s) {
              facet_fields.push(s)
            }
          }
        }
        _ => ()
      }
      match fields.get("filters") {
        Some(Array(items)) =>
          for item in items {
            if item is Object(f) {
              let field = match f.get("field") {
                Some(String(s)) => s
                _ => ""
              }
              if field == "" {
                continue
              }
              match f.get("values") {
                Some(Array(values)) =>
                  for v in values {
                    if v is String(sv) {
                      push_filter(filters, field, sv)
                    }
                  }
                _ => ()
              }
            }
          }
        _ => ()
      }
      match fields.get("aggs") {
        Some(Array(items)) =>
          for item in items {
            match parse_agg_json(item) {
              Some(spec) => aggs.push(spec)
              None => ()
            }
          }
        _ => ()
      }
      match fields.get("highlight") {
        Some(String(s)) => highlight_field = s
        _ => ()
      }
      match fields.get("explain") {
        Some(True) => want_explain = true
        _ => ()
      }
      match fields.get("knn") {
        Some(Object(k)) => {
          match k.get("field") {
            Some(String(s)) => knn_field = s
            _ => ()
          }
          match k.get("k") {
            Some(Number(n, ..)) => knn_k = n.to_int()
            _ => ()
          }
          match k.get("vector") {
            Some(Array(values)) =>
              for v in values {
                match v {
                  Number(n, ..) => knn_vector.push(n)
                  _ => ()
                }
              }
            _ => ()
          }
        }
        _ => ()
      }
      match fields.get("fusion") {
        Some(String(s)) =>
          fusion = if s == "weighted" {
            @moonseek.Weighted(double_param(params, "alpha", 0.5))
          } else {
            @moonseek.Rrf
          }
        _ => ()
      }
    }
    _ => ()
  }
  if limit > MAX_LIMIT {
    limit = MAX_LIMIT
  }
  if limit < 0 {
    limit = 0
  }
  if offset < 0 {
    offset = 0
  }
  let started = @env.now()
  if !state.cluster.is_empty() {
    // Cluster path. Hybrid retrieval is not fanned out: fusing two rankings
    // that live on different shards would need per-shard vectors and a second
    // merge, which is a different design (see docs/cluster.md).
    if !knn_vector.is_empty() && !knn_field.is_empty() {
      raise Failure::Failure(
        "hybrid (knn) search is not available in coordinator mode",
      )
    }
    // `dfs=true` asks for a ranking identical to a single-node index of the
    // same corpus: gather df/avgdl/N from every shard first, then score with
    // those. It costs one extra round trip per query, which is why it is
    // opt-in rather than the default.
    let want_dfs = bool_param(params, "dfs")
    return render_cluster(
      state,
      query,
      limit,
      started,
      want_dfs,
      facet_fields,
      aggs,
      simple_filters(filters),
    )
  }
  if !knn_vector.is_empty() && !knn_field.is_empty() {
    // Hybrid takes a different engine path: the two rankings must be fused
    // before the top-k cut, not after.
    let fused = index.hybrid_search(
      query,
      knn_vector,
      knn_field,
      limit~,
      candidate_pool=knn_k,
      fusion~,
    )
    return render_hybrid(
      state, fused, query, highlight_field, snippet_chars, started, fusion,
    )
  }
  let options : @moonseek.SearchOptions = {
    limit,
    offset,
    filters,
    facet_fields,
  }
  let result = index.search_faceted(query, options~)
  let took = (@env.now() - started).to_double()
  let fields : Map[String, Json] = Map([])
  fields["query"] = @json.to_json(query)
  fields["total"] = @json.to_json(result.total)
  fields["took_ms"] = @json.to_json(took)
  let hits : Array[Json] = []
  for hit in result.hits {
    hits.push(
      hit_json(state, hit, query, highlight_field, snippet_chars, want_explain),
    )
  }
  fields["hits"] = Json::array(hits)
  let facet_obj : Map[String, Json] = Map([])
  for (field, counts) in result.facets {
    let arr : Array[Json] = []
    for c in counts {
      arr.push(Json::array([@json.to_json(c.value), @json.to_json(c.count)]))
    }
    facet_obj[field] = Json::array(arr)
  }
  fields["facets"] = Json::object(facet_obj)
  if !aggs.is_empty() {
    let agg_results = index.aggregate(
      query,
      aggs,
      filters=simple_filters(filters),
    )
    let arr : Array[Json] = []
    for a in agg_results {
      arr.push(a.to_json())
    }
    fields["aggs"] = Json::array(arr)
  }
  // Offer a correction only when there is nothing to show; next to real results
  // a suggestion is noise.
  if result.total == 0 {
    let suggestion = index.suggest(query).unwrap_or("")
    if !suggestion.is_empty() {
      fields["suggest"] = @json.to_json(suggestion)
    }
  }
  Json::object(fields).stringify()
}

///|
fn simple_filters(
  filters : Array[@moonseek.FacetFilter],
) -> Array[(String, Array[String])] {
  let out : Array[(String, Array[String])] = []
  for f in filters {
    out.push((f.field, f.values))
  }
  out
}

///|
/// Fan a query out to the shards and render the merged answer.
///
/// Scoring uses each shard's own statistics by default. `dfs=true` switches on
/// the two-phase path: gather global `df`/`avgdl`/`N`, install them on every
/// shard, then score. Both are reported so a client can tell which ranking it
/// got, and the cluster test measures the difference between them instead of
/// asserting it away.
async fn render_cluster(
  state : ServerState,
  query : String,
  limit : Int32,
  started : UInt64,
  want_dfs : Bool,
  facet_fields : Array[String],
  aggs : Array[@moonseek.AggSpec],
  filters : Array[(String, Array[String])],
) -> String {
  let config : ClusterConfig = {
    shards: state.cluster,
    pool_per_shard: state.pool_per_shard,
    timeout_ms: 2000,
  }
  // Phase one, only when the client asked for consistent scoring. A query whose
  // term set is shard-dependent (a prefix) cannot be handled this way, and
  // saying so is better than silently mixing two rankings.
  let mut dfs_applied = false
  let mut dfs_note = ""
  let stats : @moonseek.ExternalStats? = if want_dfs {
    match query_terms_local(state, query) {
      Some(terms) => {
        let gathered = cluster_gather_stats(config, terms)
        match gathered {
          Some(_) => {
            dfs_applied = true
            gathered
          }
          None => {
            dfs_note = "no shard answered the statistics round"
            None
          }
        }
      }
      None => {
        dfs_note = "query has shard-dependent terms (prefix); dfs not applied"
        None
      }
    }
  } else {
    None
  }
  let result = cluster_search(config, query, limit, stats, filters)
  let took = (@env.now() - started).to_double()
  let fields : Map[String, Json] = Map([])
  fields["query"] = @json.to_json(query)
  fields["total"] = @json.to_json(result.total)
  fields["took_ms"] = @json.to_json(took)
  fields["dfs"] = @json.to_json(dfs_applied)
  if !dfs_note.is_empty() {
    fields["dfs_note"] = @json.to_json(dfs_note)
  }
  let hits : Array[Json] = []
  for (id, score) in result.hits {
    let entry : Map[String, Json] = Map([])
    entry["id"] = @json.to_json(id)
    entry["score"] = @json.to_json(score)
    hits.push(Json::object(entry))
  }
  fields["hits"] = Json::array(hits)
  // Facets and aggregations are computed over the whole corpus, not over the
  // coordinator's own empty index. A facet is an uncapped terms aggregation
  // over the filtered result set, so both go through the same fan-out and the
  // same merge — one round trip for a query that asks for either.
  let specs : Array[@moonseek.AggSpec] = []
  for field in facet_fields {
    specs.push(@moonseek.TermsAgg(field, 0))
  }
  for spec in aggs {
    specs.push(spec)
  }
  let mut merged : Array[@moonseek.AggResult] = []
  let agg_failed : Array[String] = []
  if specs.length() > 0 {
    let (results, failed_addresses, _) = cluster_aggregate(
      config, query, specs, filters,
    )
    merged = results
    for address in failed_addresses {
      agg_failed.push(address)
    }
  }
  let facet_obj : Map[String, Json] = Map([])
  for i in 0..<facet_fields.length() {
    if i >= merged.length() {
      break
    }
    let arr : Array[Json] = []
    for (label, count) in merged[i].buckets {
      arr.push(Json::array([@json.to_json(label), @json.to_json(count)]))
    }
    facet_obj[facet_fields[i]] = Json::array(arr)
  }
  fields["facets"] = Json::object(facet_obj)
  if !aggs.is_empty() {
    let arr : Array[Json] = []
    for i in facet_fields.length()..<merged.length() {
      arr.push(merged[i].to_json())
    }
    fields["aggs"] = Json::array(arr)
  }
  if agg_failed.length() > 0 {
    // The ranking may be complete while the aggregation is not, so this is a
    // separate field rather than folded into the search's shard accounting:
    // a facet total from two of three shards is a smaller number presented as a
    // count of the corpus, which is a failure a dashboard would not notice.
    let arr : Array[Json] = []
    for address in agg_failed {
      arr.push(@json.to_json(address))
    }
    fields["agg_failed_addresses"] = Json::array(arr)
  }
  // The shard accounting is part of the contract: a partial answer must say so.
  let shards : Map[String, Json] = Map([])
  shards["total"] = @json.to_json(result.shards_total)
  shards["ok"] = @json.to_json(result.shards_ok)
  shards["failed"] = @json.to_json(result.shards_failed)
  let failed : Array[Json] = []
  for address in result.failed {
    failed.push(@json.to_json(address))
  }
  shards["failed_addresses"] = Json::array(failed)
  fields["shards"] = Json::object(shards)
  Json::object(fields).stringify()
}

///|
/// The (field, term) pairs a query would score, resolved against the schema
/// this process declares. Used to decide which statistics a df-gathering round
/// needs to fetch.
fn query_terms_local(
  state : ServerState,
  query : String,
) -> Array[(String, String)]? {
  let names : Array[String] = []
  for f in state.schema {
    names.push(f.name)
  }
  let probe = @moonseek.Index::new(state.schema)
  let parsed = @moonseek.parse_query(
    query,
    analyzer=probe.analyzer(),
    fields=names,
  ) catch {
    _ => return None
  }
  @moonseek.scoring_terms(probe, parsed)
}

///|
/// Merge a filter value in: repeated `filter=license:MIT` and
/// `filter=license:Apache-2.0` mean "either", while different fields mean "and".
fn push_filter(
  filters : Array[@moonseek.FacetFilter],
  field : String,
  value : String,
) -> Unit {
  for i in 0..<filters.length() {
    if filters[i].field == field {
      filters[i].values.push(value)
      return ()
    }
  }
  filters.push({ field, values: [value], })
}

///|
/// `field:terms[:size]` / `field:stats` / `field:histogram:interval` /
/// `field:percentiles` shorthand for the query-string form.
fn parse_agg_shorthand(text : String) -> @moonseek.AggSpec? {
  // split() yields StringViews; materialize to owned Strings so the match below
  // can bind them by value.
  let parts : Array[String] = []
  for piece in text.split(":") {
    parts.push(piece.to_owned())
  }
  match parts {
    [field, "terms"] => Some(@moonseek.TermsAgg(field, 10))
    [field, "terms", size] =>
      Some(@moonseek.TermsAgg(field, @string.parse_int(size) catch { _ => 10 }))
    [field, "stats"] => Some(@moonseek.StatsAgg(field))
    [field, "histogram", interval] =>
      Some(
        @moonseek.HistogramAgg(
          field,
          @string.parse_double(interval) catch {
            _ => 1.0
          },
        ),
      )
    [field, "percentiles"] =>
      Some(@moonseek.PercentilesAgg(field, [50.0, 90.0, 99.0]))
    _ => None
  }
}

///|
/// `{"kind":"terms","field":"license","size":10}` from the JSON form; `type` is
/// accepted as an alias because that is what the console sends.
fn parse_agg_json(item : Json) -> @moonseek.AggSpec? {
  match item {
    Object(fields) => {
      let kind = match fields.get("kind") {
        Some(String(s)) => s
        _ =>
          match fields.get("type") {
            Some(String(s)) => s
            _ => ""
          }
      }
      let field = match fields.get("field") {
        Some(String(s)) => s
        _ => ""
      }
      if field == "" {
        return None
      }
      match kind {
        "terms" => {
          let size = match fields.get("size") {
            Some(Number(n, ..)) => n.to_int()
            _ => 10
          }
          Some(@moonseek.TermsAgg(field, size))
        }
        "stats" => Some(@moonseek.StatsAgg(field))
        "histogram" => {
          let interval = match fields.get("interval") {
            Some(Number(n, ..)) => n
            _ => 1.0
          }
          Some(@moonseek.HistogramAgg(field, interval))
        }
        "percentiles" => {
          let ps : Array[Double] = []
          match fields.get("percentiles") {
            Some(Array(items)) =>
              for v in items {
                match v {
                  Number(n, ..) => ps.push(n)
                  _ => ()
                }
              }
            _ => ()
          }
          if ps.is_empty() {
            ps.push(50.0)
            ps.push(90.0)
            ps.push(99.0)
          }
          Some(@moonseek.PercentilesAgg(field, ps))
        }
        _ => None
      }
    }
    _ => None
  }
}

///|
/// One hit as JSON. The snippet comes from the engine (escaped, with CJK-aware
/// `<mark>` spans), not from string surgery here.
fn hit_json(
  state : ServerState,
  hit : @moonseek.Hit,
  query : String,
  highlight_field : String,
  snippet_chars : Int32,
  want_explain : Bool,
) -> Json {
  let index = state.index
  let fields : Map[String, Json] = Map([])
  fields["id"] = @json.to_json(hit.id)
  fields["score"] = @json.to_json(hit.score)
  let stored : Map[String, Json] = Map([])
  for f in state.schema {
    match index.get_field(hit.id, f.name) {
      Some(text) => stored[f.name] = @json.to_json(text)
      None => ()
    }
  }
  fields["fields"] = Json::object(stored)
  let snippet = index.snippet(
    hit.id,
    highlight_field,
    query,
    max_chars=snippet_chars,
  ) catch {
    _ => ""
  }
  fields["snippet"] = @json.to_json(snippet)
  if want_explain {
    let explained : @moonseek.Explanation? = index.explain(query, hit.id) catch {
      _ => None
    }
    match explained {
      Some(e) => fields["explain"] = e.to_json()
      None => ()
    }
  }
  Json::object(fields)
}

///|
fn render_hybrid(
  state : ServerState,
  fused : Array[@moonseek.HybridHit],
  query : String,
  highlight_field : String,
  snippet_chars : Int32,
  started : UInt64,
  fusion : @moonseek.Fusion,
) -> String {
  let took = (@env.now() - started).to_double()
  let fields : Map[String, Json] = Map([])
  fields["query"] = @json.to_json(query)
  fields["total"] = @json.to_json(fused.length())
  fields["took_ms"] = @json.to_json(took)
  fields["fusion"] = @json.to_json(
    match fusion {
      @moonseek.Rrf => "rrf"
      @moonseek.Weighted(_) => "weighted"
    },
  )
  let hits : Array[Json] = []
  for h in fused {
    let hit : @moonseek.Hit = { id: h.id, score: h.score, }
    let json = hit_json(
      state, hit, query, highlight_field, snippet_chars, false,
    )
    match json {
      Object(map) => {
        map["lexical_rank"] = @json.to_json(h.lexical_rank)
        map["vector_rank"] = @json.to_json(h.vector_rank)
      }
      _ => ()
    }
    hits.push(json)
  }
  fields["hits"] = Json::array(hits)
  fields["facets"] = Json::object(Map([]))
  Json::object(fields).stringify()
}

///|
/// Apply one document JSON object: fields, facets, numeric values, vectors.
fn apply_document(state : ServerState, body : String) -> String raise {
  let json = @json.parse(body)
  let index = state.index
  let obj = match json {
    Object(o) => o
    _ => raise Failure::Failure("document must be a JSON object")
  }
  let id = match obj.get("id") {
    Some(String(s)) => s
    _ => raise Failure::Failure("document needs a string id")
  }
  let values : Map[String, String] = Map([])
  match obj.get("fields") {
    Some(Object(fs)) =>
      for (name, value) in fs.iter() {
        match value {
          String(s) => values[name] = s
          _ => ()
        }
      }
    _ => ()
  }
  // Every declared field must be present in the document or `add` aborts on the
  // missing ones, so the gaps are filled with empty text.
  let doc_fields : Array[(String, String)] = []
  for f in state.schema {
    doc_fields.push((f.name, values.get_or_default(f.name, "")))
  }
  index.add({ id, fields: doc_fields, })
  match obj.get("facets") {
    Some(Object(fs)) => {
      let facets : Array[(String, Array[String])] = []
      for (name, value) in fs.iter() {
        match value {
          Array(items) => {
            let vals : Array[String] = []
            for v in items {
              if v is String(s) {
                vals.push(s)
              }
            }
            facets.push((name, vals))
          }
          String(single) => facets.push((name, [single]))
          _ => ()
        }
      }
      let _ = index.set_facets(id, facets)
    }
    _ => ()
  }
  match obj.get("nums") {
    Some(Object(ns)) =>
      for (name, value) in ns.iter() {
        match value {
          Number(n, ..) => {
            let _ = index.set_num(id, name, n)
          }
          _ => ()
        }
      }
    _ => ()
  }
  match obj.get("vector") {
    Some(Object(vs)) =>
      for (name, value) in vs.iter() {
        match value {
          Array(items) => {
            let vec : Array[Double] = []
            for v in items {
              match v {
                Number(n, ..) => vec.push(n)
                _ => ()
              }
            }
            if !index.set_vector(id, name, vec) {
              let fields : Map[String, Json] = Map([])
              fields["error"] = @json.to_json(
                "vector rejected: dimensionality mismatch for field " + name,
              )
              fields["code"] = @json.to_json("bad_request")
              return Json::object(fields).stringify()
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  let out : Map[String, Json] = Map([])
  out["ok"] = @json.to_json(true)
  out["id"] = @json.to_json(id)
  Json::object(out).stringify()
}

///|
/// `POST /index/bulk`: newline-delimited JSON documents.
fn index_bulk(state : ServerState, body : String) -> String {
  let started = @env.now()
  let mut indexed = 0
  let mut failed = 0
  let first_error : Array[String] = []
  for line in body.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed.is_empty() {
      continue
    }
    let text = apply_document(state, trimmed) catch {
      _ => {
        failed += 1
        continue
      }
    }
    // apply_document reports a rejected vector in its body rather than by
    // raising, so bulk ingest has to inspect it to count honestly.
    if text.contains("\"error\"") {
      failed += 1
      if first_error.is_empty() {
        first_error.push(text)
      }
    } else {
      indexed += 1
    }
  }
  state.indexed_docs += indexed.to_int64()
  let took = (@env.now() - started).to_double()
  let fields : Map[String, Json] = Map([])
  fields["indexed"] = @json.to_json(indexed)
  fields["failed"] = @json.to_json(failed)
  fields["took_ms"] = @json.to_json(took)
  if !first_error.is_empty() {
    fields["first_error"] = @json.to_json(first_error[0])
  }
  Json::object(fields).stringify()
}
