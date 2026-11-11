///|
/// Large-scale benchmark: up to a million synthetic documents.
///
/// Companion to bench/stress (20k docs). This harness exists to answer the
/// question the small corpus cannot: what does the engine do when the corpus
/// is large enough that resident memory, not instruction count, is the
/// binding constraint.
///
/// Run:
///   moon run bench/scale --target native --release -- --docs 200000
///   moon run bench/scale --target native --release -- --docs 1000000
///
/// Two engineering points the report depends on:
///
/// 1. Streaming corpus. Documents are generated one at a time, handed to
///    `Index::add`, and dropped; the harness never holds the whole corpus in
///    its own array, so it does not add a second copy of the text to RSS.
///    The index *does* keep every document's original field text (there is
///    no "index without stored fields" switch in 0.6.0), so peak memory is
///    dominated by the index, not by this file. `estimate_memory` prints the
///    components it can measure and states the model for the rest.
///
/// 2. Honest reporting. Build time is a median of repeated runs wherever the
///    scale makes that affordable, and is labelled `single run` where it is
///    not. Query latency is p50/p50/p99 of 200 samples after a warm-up, not a
///    best-of batch. Every query shape prints the number of documents it
///    actually matched, so a row can never silently time an empty posting
///    list. Post-tombstone numbers are reported next to the clean ones rather
///    than instead of them.

///|
/// Deterministic xorshift64 RNG (same generator as bench/stress, so the two
/// corpora are comparable in construction if not in size).
struct Rng {
  mut state : UInt64
}

///|
fn Rng::new(seed : UInt64) -> Rng {
  { state: seed, }
}

///|
fn Rng::next(self : Rng) -> UInt64 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  self.state = x
  x
}

///|
fn Rng::below(self : Rng, n : Int32) -> Int32 {
  (self.next() % n.to_uint64()).to_int()
}

///|
/// Realistic English/Chinese anchor words mixed into the corpus. Index 0 and
/// index 7 are used as the exact-phrase pair (see `make_index`); keep them
/// adjacent-in-title if you reorder this list.
fn anchors() -> Array[String] {
  [
    "search", "engine", "index", "query", "language", "moonbit", "wasm", "compiler",
    "runtime", "memory", "safety", "fast", "embedded", "database", "distributed",
    "consensus", "storage", "segment", "merge", "ranking", "全文", "搜索", "引擎",
    "倒排", "索引", "分词", "排序", "算法", "数据库", "存储",
  ]
}

///|
const SEED : UInt64 = 0x9E3779B97F4A7C15UL

///|
/// The schema every measurement in this file uses.
fn schema() -> Array[@moonseek.FieldSchema] {
  [{ name: "title", weight: 3.0, }, { name: "body", weight: 1.0, }]
}

///|
/// Microseconds -> milliseconds.
fn us_ms(us : Double) -> Double {
  us / 1000.0
}

///|
/// Fixed-decimal formatting without locale or exponent surprises.
fn fmt(x : Double, digits : Int32) -> String {
  let mut scale = 1.0
  for _ in 0..<digits {
    scale = scale * 10.0
  }
  let scaled = (x * scale).round().to_int()
  let whole = scaled / scale.to_int()
  if digits == 0 {
    return whole.to_string()
  }
  let mut frac = (scaled % scale.to_int()).abs()
  let mut s = ""
  let mut i = 0
  while i < digits {
    s = (frac % 10).to_string() + s
    frac = frac / 10
    i += 1
  }
  whole.to_string() + "." + s
}

///|
/// Bytes -> mebibytes as a Double.
fn mb(bytes : Int32) -> Double {
  bytes.to_double() / 1048576.0
}

///|
/// Parse a non-negative decimal integer. Returns None on any other input, so
/// a typo never silently becomes the default.
fn parse_int_string(s : String) -> Int32? {
  let chars = s.to_array()
  if chars.length() == 0 {
    return None
  }
  let mut n = 0
  for c in chars {
    let d = c.to_int() - 48
    if d < 0 || d > 9 {
      return None
    }
    n = n * 10 + d
  }
  Some(n)
}

///|
/// The p-th percentile of an ascending array (nearest-rank).
fn percentile(sorted : Array[Double], p : Int32) -> Double {
  if sorted.length() == 0 {
    return 0.0
  }
  let mut idx = sorted.length() * p / 100
  if idx >= sorted.length() {
    idx = sorted.length() - 1
  }
  if idx < 0 {
    idx = 0
  }
  sorted[idx]
}

///|
/// Synthetic vocabulary index candidates, geometric so that the same list
/// works at 100k and at 1M documents. The generated term is `w{k}x`.
fn candidate_ks() -> Array[Int32] {
  [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15, 20, 25, 32, 40, 50, 64, 80, 100, 125,
    160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000,
    5000, 6400, 8000, 10000, 12500, 16000, 20000, 25000, 32000, 40000, 50000, 64000,
    80000, 100000, 125000, 160000, 199999,
  ]
}

///|
/// Pick the term `w{k}x` whose document frequency is closest to `target`.
///
/// The stress harness hardcoded term names; two of them did not exist in the
/// generated corpus and were silently timing an empty posting list. Selecting
/// by measured df removes that class of mistake.
fn pick_term(
  idx : @moonseek.Index,
  field : String,
  target : Int32,
  vocab : Int32,
) -> (String, Int32) {
  let mut best = ("", -1)
  let mut best_delta = 1 << 30
  for k in candidate_ks() {
    if k >= vocab {
      continue
    }
    let t = "w" + k.to_string() + "x"
    let df = idx.doc_freq(field, t)
    let d = (df - target).abs()
    if d < best_delta {
      best_delta = d
      best = (t, df)
    }
  }
  best
}

///|
/// The term with the highest document frequency among the anchors and the
/// very first synthetic words — i.e. the saturated case.
fn pick_saturated(idx : @moonseek.Index) -> (String, Int32) {
  let cands : Array[String] = []
  for w in anchors() {
    cands.push(w)
  }
  cands.push("w0x")
  cands.push("w1x")
  cands.push("w2x")
  cands.push("w3x")
  let mut best = ("", -1)
  for t in cands {
    let df = idx.doc_freq("body", t)
    if df > best.1 {
      best = (t, df)
    }
  }
  best
}

///|
/// Choose a synthetic prefix whose term expansion is closest to 100 terms.
///
/// Prefixes are built by truncating `w{vocab-1}` at a digit boundary, which
/// keeps the matching terms contiguous in lexicographic order. Counting walks
/// the (cached, sorted) term list once per candidate; at most six candidates,
/// so this is a one-off O(vocab) cost, not a per-query one.
fn pick_prefix(idx : @moonseek.Index, vocab : Int32) -> (String, Int32) {
  let terms = idx.terms_of("body")
  let digits = (vocab - 1).to_string()
  let mut best = ("", -1)
  let mut best_delta = 1 << 30
  let mut l = 1
  while l <= digits.length() {
    let p = "w" + digits[:l].to_owned()
    let mut count = 0
    for t in terms {
      if t.has_prefix(p) {
        count += 1
      }
    }
    let d = (count - 100).abs()
    if d < best_delta {
      best_delta = d
      best = (p, count)
    }
    l += 1
  }
  best
}

///|
/// Build an index over `docs` generated documents and return
/// `(index, raw_text_bytes, total_tokens)`.
///
/// Streaming: one document's `String`s exist at a time. The counts are taken
/// during generation so the memory model has measured inputs even when the
/// postings themselves are too large to enumerate.
fn make_index(
  docs : Int32,
  vocab : Int32,
  verbose : Bool,
) -> (@moonseek.Index, Int32, Int32) {
  let words : Array[String] = []
  for i in 0..<vocab {
    words.push("w" + i.to_string() + "x")
  }
  let aw = anchors()
  let ac = aw.length()
  let rng = Rng::new(SEED)
  let idx = @moonseek.Index::new(schema())
  let mut raw_bytes = 0
  let mut total_tokens = 0
  for i in 0..<docs {
    let body : Array[String] = []
    let len = 40 + rng.below(60)
    for _ in 0..<len {
      // 10% anchors (real prose), 90% Zipf-ish synthetic. The squared index
      // is computed in 64-bit: vocab^2 overflows Int32 for vocab > 46340.
      if rng.below(10) == 0 {
        body.push(aw[rng.below(ac)])
      } else {
        let u = rng.below(vocab)
        let k = (u.to_uint64() * u.to_uint64() / vocab.to_uint64()).to_int()
        body.push(words[k])
      }
    }
    let body_text = body.join(" ")
    // Title carries a rotating anchor pair so the exact-phrase query has a
    // known, measurable df (~docs/30) instead of depending on chance.
    let title = "document " +
      i.to_string() +
      " " +
      aw[i % ac] +
      " " +
      aw[(i + 7) % ac]
    idx.add({
      id: "doc-" + i.to_string(),
      fields: [("title", title), ("body", body_text)],
    })
    raw_bytes += title.length() + body_text.length()
    total_tokens += len + 4
    if verbose && i > 0 && i % 200000 == 0 {
      println("  indexed " + i.to_string() + " / " + docs.to_string())
    }
  }
  (idx, raw_bytes, total_tokens)
}

///|
/// One query shape's measured latency and match count.
struct ShapeResult {
  p50 : Double
  p90 : Double
  p99 : Double
  matches : Int32
  sink : Int32
}

///|
/// Warm up, count matches once (untimed, `limit=0` so the count is the true
/// match set), then time `samples` calls at `limit=10` (the UI page size).
/// `sink` accumulates the returned hit counts so the loop cannot be optimised
/// away.
fn timed_search(
  idx : @moonseek.Index,
  q : String,
  samples : Int32,
  warmup : Int32,
) -> ShapeResult {
  for _ in 0..<warmup {
    let _ = idx.search(q, limit=10) catch { _ => [] }
  }
  let matches = (idx.search(q, limit=0) catch { _ => [] }).length()
  let xs : Array[Double] = []
  let mut sink = 0
  for _ in 0..<samples {
    let t = @bench.monotonic_clock_start()
    let hits = idx.search(q, limit=10) catch { _ => [] }
    let e = @bench.monotonic_clock_end(t)
    xs.push(e)
    sink += hits.length()
  }
  xs.sort()
  {
    p50: percentile(xs, 50),
    p90: percentile(xs, 90),
    p99: percentile(xs, 99),
    matches,
    sink,
  }
}

///|
/// Count postings and positions by walking the built index. Only used at
/// modest scale; at a million documents the walk is the dominant cost and the
/// totals are taken from the generator instead.
fn enumerate_postings(idx : @moonseek.Index) -> (Int32, Int32) {
  let mut postings = 0
  let mut positions = 0
  for field in ["title", "body"] {
    for term in idx.terms_of(field) {
      for p in idx.postings_of(field, term) {
        postings += 1
        positions += p.positions.length()
      }
    }
  }
  (postings, positions)
}

///|
/// Deserialize or return None; lets the caller time `from_bytes` without an
/// unwieldy result type.
fn try_from_bytes(img : Bytes) -> @moonseek.Index? {
  let ix = @moonseek.Index::from_bytes(img) catch { _ => return None }
  Some(ix)
}

///|
/// `(snapshot_mb, serialize_ms, deserialize_ms, deserialize_ok)`.
///
/// Kept in its own function so the snapshot buffer and the restored index
/// fall out of scope on return: at a million documents the image is hundreds
/// of megabytes and must not be pinned through the deletion phase.
fn snapshot_stats(
  idx : @moonseek.Index,
  roundtrip : Bool,
) -> (Double, Double, Double, Bool) {
  let t = @bench.monotonic_clock_start()
  let img = idx.to_bytes()
  let e = @bench.monotonic_clock_end(t)
  let size_mb = mb(img.length())
  let ser_ms = us_ms(e)
  let mut deser_ms = 0.0
  let mut ok = false
  if roundtrip {
    let t2 = @bench.monotonic_clock_start()
    let restored = try_from_bytes(img)
    let e2 = @bench.monotonic_clock_end(t2)
    deser_ms = us_ms(e2)
    match restored {
      Some(r) => ok = idx.doc_count() == r.doc_count()
      None => ()
    }
  }
  (size_mb, ser_ms, deser_ms, ok)
}

///|
/// The numbers the Markdown row and the JSON sidecar are built from.
struct Metrics {
  terms : Int32
  snapshot_mb : Double
  ser_ms : Double
  deser_ms : Double
  deser_ok : Bool
  sel_p50 : Double
  sat_p50 : Double
  sat_p99 : Double
  deleted : Int32
  del_sat_p50 : Double
  est_index_mb : Double
  postings : Int32
  positions : Int32
  enumerated : Bool
}

///|
/// Run every query/deletion/snapshot/memory measurement against a built
/// index and print the detailed sections.
fn measure(
  idx : @moonseek.Index,
  docs : Int32,
  samples : Int32,
  roundtrip : Bool,
  raw_bytes : Int32,
  total_tokens : Int32,
  vocab : Int32,
) -> Metrics {
  let terms = idx.term_count()
  println("=== index ===")
  println(
    "  docs=" +
    idx.doc_count().to_string() +
    " terms=" +
    terms.to_string() +
    " raw_text=" +
    (if raw_bytes == 0 {
      "n/a (loaded snapshot)"
    } else {
      fmt(mb(raw_bytes), 1) + " MB"
    }),
  )
  // ---- query latency, clean index ----
  println(
    "=== query latency (p50/p90/p99 of " +
    samples.to_string() +
    " samples, 10 warmup, limit=10) ===",
  )
  let sel = pick_term(idx, "body", 100, vocab)
  let mid = pick_term(idx, "body", docs / 50, vocab)
  let sat = pick_saturated(idx)
  let a = anchors()
  let phrase_q = "\"" + a[0] + " " + a[7] + "\""
  let sloppy_q = "\"" + a[0] + " " + a[7] + "\"~3"
  let bool_q = a[0] + " AND " + a[1]
  let pfx = pick_prefix(idx, vocab)
  let labels : Array[String] = [
    "selective term (df~100)", "mid term (df~docs/50)", "saturated term", "boolean AND",
    "exact phrase", "sloppy phrase ~3", "prefix expansion", "field-scoped title:",
  ]
  let queries : Array[String] = [
    sel.0,
    mid.0,
    sat.0,
    bool_q,
    phrase_q,
    sloppy_q,
    pfx.0 + "*",
    "title:" + a[0],
  ]
  println(
    "  picked: selective=" +
    sel.0 +
    " (df " +
    sel.1.to_string() +
    "), mid=" +
    mid.0 +
    " (df " +
    mid.1.to_string() +
    "), saturated=" +
    sat.0 +
    " (df " +
    sat.1.to_string() +
    "), prefix=" +
    pfx.0 +
    " (" +
    pfx.1.to_string() +
    " terms)",
  )
  let results : Array[ShapeResult] = []
  for i in 0..<labels.length() {
    let r = timed_search(idx, queries[i], samples, 10)
    results.push(r)
    println(
      "  " +
      labels[i] +
      " matches=" +
      r.matches.to_string() +
      ": p50 " +
      fmt(us_ms(r.p50), 3) +
      " ms  p90 " +
      fmt(us_ms(r.p90), 3) +
      "  p99 " +
      fmt(us_ms(r.p99), 3) +
      "  (sink " +
      r.sink.to_string() +
      ")",
    )
  }
  // ---- snapshot ----
  println("=== snapshot ===")
  let (snapshot_mb, ser_ms, deser_ms, deser_ok) = snapshot_stats(idx, roundtrip)
  println(
    "  serialize: " + fmt(ser_ms, 1) + " ms, " + fmt(snapshot_mb, 1) + " MB",
  )
  if roundtrip {
    println(
      "  deserialize: " +
      fmt(deser_ms, 1) +
      " ms, doc_count parity=" +
      deser_ok.to_string(),
    )
  } else {
    println(
      "  deserialize: skipped at this scale (image + restored index would both be resident)",
    )
  }
  // ---- deletion / tombstone cost ----
  println("=== after deleting 10% (tombstone cost) ===")
  let td = @bench.monotonic_clock_start()
  let mut deleted = 0
  for i in 0..<docs {
    if i % 10 == 0 {
      if idx.delete("doc-" + i.to_string()) {
        deleted += 1
      }
    }
  }
  let ed = @bench.monotonic_clock_end(td)
  println(
    "  deleted " +
    deleted.to_string() +
    " docs in " +
    fmt(us_ms(ed), 1) +
    " ms; doc_count=" +
    idx.doc_count().to_string(),
  )
  // A K-term query now pays O(K * N) because avg field length is recomputed
  // per BM25 context while tombstones exist; keep this phase small and skip
  // the wide prefix case so the run stays bounded.
  let del_samples = if samples > 50 { 50 } else { samples }
  let post_idxs : Array[Int32] = [0, 2, 3, 4]
  let mut del_sat_p50 = 0.0
  for i in post_idxs {
    let r = timed_search(idx, queries[i], del_samples, 5)
    if i == 2 {
      del_sat_p50 = r.p50
    }
    println(
      "  " +
      labels[i] +
      " (post-delete) matches=" +
      r.matches.to_string() +
      ": p50 " +
      fmt(us_ms(r.p50), 3) +
      " ms  p99 " +
      fmt(us_ms(r.p99), 3) +
      "  [clean p50 " +
      fmt(us_ms(results[i].p50), 3) +
      " ms]",
    )
  }
  // ---- memory model ----
  println("=== memory (model, not an in-process RSS reading) ===")
  let enumerated = docs <= 400000
  let postings = if enumerated {
    enumerate_postings(idx).0
  } else {
    total_tokens
  }
  let positions = if enumerated {
    enumerate_postings(idx).1
  } else {
    total_tokens
  }
  println(
    "  stored field text (measured, sum of generated bytes): " +
    fmt(mb(raw_bytes), 1) +
    " MB",
  )
  println(
    "  postings: " +
    postings.to_string() +
    (if enumerated { " (enumerated)" } else { " (from generated token count)" }),
  )
  println(
    "  positions: " +
    positions.to_string() +
    (if enumerated { " (enumerated)" } else { " (from generated token count)" }),
  )
  // Model: raw text + 48 B per posting (doc + freq + positions pointer inline
  // in Array[Posting], plus one positions array header) + 100 B per distinct
  // term (term string + hashmap entry + list header). ESTIMATE.
  let est_bytes = raw_bytes + postings * 48 + terms * 100
  let est_index_mb = mb(est_bytes)
  println(
    "  ESTIMATED resident index: " +
    fmt(est_index_mb, 1) +
    " MB  (raw_text + postings*48B + terms*100B)",
  )
  println(
    "  peak RSS: NOT measured in-process (core/env exposes no memory API);",
  )
  println("            measure externally, e.g. PowerShell")
  println("            `Get-Process scale | Select -Expand WorkingSet64`")
  {
    terms,
    snapshot_mb,
    ser_ms,
    deser_ms,
    deser_ok,
    sel_p50: results[0].p50,
    sat_p50: results[2].p50,
    sat_p99: results[2].p99,
    deleted,
    del_sat_p50,
    est_index_mb,
    postings,
    positions,
    enumerated,
  }
}

///|
const TABLE_HEADER : String = "| scale (docs) | build docs/s | selective p50 (ms) | saturated p50 (ms) | saturated p99 (ms) | snapshot (MB) |"

///|
const TABLE_SEP : String = "|---:|---:|---:|---:|---:|---:|"

///|
/// Merge this run's row into an existing table (by the scale column), so
/// running 200k then 1M produces one two-row table. Unparseable input is
/// discarded in favour of a fresh table.
fn render_table(existing : String, new_row : String, new_key : Int32) -> String {
  let rows : Array[(Int32, String)] = []
  for line in existing.split("\n") {
    let l = line.trim().to_owned()
    if l.has_prefix("|") && !l.contains("---") && !l.contains("scale") {
      let parts : Array[String] = []
      for p in l.split("|") {
        parts.push(p.to_owned())
      }
      if parts.length() >= 2 {
        match parse_int_string(parts[1].trim().to_owned()) {
          Some(n) => rows.push((n, l))
          None => ()
        }
      }
    }
  }
  let mut replaced = false
  for i in 0..<rows.length() {
    if rows[i].0 == new_key {
      rows[i] = (new_key, new_row)
      replaced = true
    }
  }
  if !replaced {
    rows.push((new_key, new_row))
  }
  rows.sort_by(fn(x, y) { x.0 - y.0 })
  let lines : Array[String] = [TABLE_HEADER, TABLE_SEP]
  for r in rows {
    lines.push(r.1)
  }
  lines.join("\n") + "\n"
}

///|
/// JSON sidecar so a sweep can be plotted or diffed without re-parsing the
/// console output. Written with `@json`'s constructors only (no indexing into
/// parsed JSON, which the 0.10 deprecation replaced with pattern matching).
fn render_json(
  docs : Int32,
  vocab : Int32,
  docs_per_s : Double,
  m : Metrics,
  build_med_ms : Double,
  build_single : Bool,
) -> String {
  let root : Map[String, Json] = Map([])
  root["docs"] = @json.to_json(docs)
  root["vocab"] = @json.to_json(vocab)
  root["build_median_ms"] = @json.to_json(build_med_ms)
  root["build_single_run"] = @json.to_json(build_single)
  root["docs_per_s"] = @json.to_json(docs_per_s)
  root["terms"] = @json.to_json(m.terms)
  root["snapshot_mb"] = @json.to_json(m.snapshot_mb)
  root["serialize_ms"] = @json.to_json(m.ser_ms)
  root["deserialize_ms"] = @json.to_json(m.deser_ms)
  root["deserialize_ok"] = @json.to_json(m.deser_ok)
  root["selective_p50_us"] = @json.to_json(m.sel_p50)
  root["saturated_p50_us"] = @json.to_json(m.sat_p50)
  root["saturated_p99_us"] = @json.to_json(m.sat_p99)
  root["deleted_docs"] = @json.to_json(m.deleted)
  root["post_delete_saturated_p50_us"] = @json.to_json(m.del_sat_p50)
  root["postings"] = @json.to_json(m.postings)
  root["positions"] = @json.to_json(m.positions)
  root["postings_enumerated"] = @json.to_json(m.enumerated)
  root["est_index_mb"] = @json.to_json(m.est_index_mb)
  root["peak_rss"] = @json.to_json("not measured in-process")
  Json::object(root).stringify(indent=2)
}

///|
fn usage() -> String {
  "usage: moon run bench/scale --target native --release -- [options]\n" +
  "  --docs N        document count (default 1000000)\n" +
  "  --vocab V       synthetic vocabulary size (default 200000)\n" +
  "  --out FILE      write (merge) the Markdown headline table\n" +
  "  --json FILE     write a JSON sidecar of the raw numbers\n" +
  "  --samples N     query samples per shape (default 200)\n" +
  "  --runs N        build runs (default: 3 up to 300k docs, else 1)\n" +
  "  --skip-build    do not build; load --index instead\n" +
  "  --index FILE    snapshot to load when --skip-build is set\n" +
  "  --save-index F  write the built index as a snapshot to F\n" +
  "  --no-roundtrip  skip snapshot deserialize at large scale"
}

///|
/// Read a file, returning "" if it does not exist or cannot be decoded.
async fn read_or_empty(path : String) -> String {
  let raw = @fs.read_file(path) catch { _ => return "" }
  let text = raw.text() catch { _ => return "" }
  text
}

///|
async fn main {
  let argv = @env.args()
  let mut docs = 1000000
  let mut vocab = 200000
  let mut out_path : String? = None
  let mut index_path : String? = None
  let mut save_index_path : String? = None
  let mut json_path : String? = None
  let mut samples = 200
  let mut build_runs = 0
  let mut skip_build = false
  let mut roundtrip = true
  let mut force_roundtrip = false
  let mut i = 1
  while i < argv.length() {
    let key = argv[i]
    let has_val = i + 1 < argv.length()
    if key == "--docs" && has_val {
      match parse_int_string(argv[i + 1]) {
        Some(n) => docs = n
        None => println("bad --docs value, keeping default")
      }
      i += 2
    } else if key == "--vocab" && has_val {
      match parse_int_string(argv[i + 1]) {
        Some(n) => vocab = n
        None => println("bad --vocab value, keeping default")
      }
      i += 2
    } else if key == "--out" && has_val {
      out_path = Some(argv[i + 1])
      i += 2
    } else if key == "--json" && has_val {
      json_path = Some(argv[i + 1])
      i += 2
    } else if key == "--index" && has_val {
      index_path = Some(argv[i + 1])
      i += 2
    } else if key == "--save-index" && has_val {
      save_index_path = Some(argv[i + 1])
      i += 2
    } else if key == "--samples" && has_val {
      match parse_int_string(argv[i + 1]) {
        Some(n) => samples = n
        None => println("bad --samples value, keeping default")
      }
      i += 2
    } else if key == "--runs" && has_val {
      match parse_int_string(argv[i + 1]) {
        Some(n) => build_runs = n
        None => println("bad --runs value, keeping default")
      }
      i += 2
    } else if key == "--skip-build" {
      skip_build = true
      i += 1
    } else if key == "--no-roundtrip" {
      roundtrip = false
      i += 1
    } else if key == "--roundtrip" {
      roundtrip = true
      force_roundtrip = true
      i += 1
    } else if key == "--help" {
      println(usage())
      return ()
    } else {
      println("ignoring unknown argument: " + key)
      i += 1
    }
  }
  let wall0 = @env.now()
  println("=== moonseek large-scale benchmark ===")
  println(
    "target=native/release docs=" +
    docs.to_string() +
    " vocab=" +
    vocab.to_string() +
    (if skip_build { " (skip-build)" } else { "" }),
  )
  let mut idx : @moonseek.Index = @moonseek.Index::new(schema())
  let mut raw_bytes = 0
  let mut total_tokens = 0
  let mut build_med_ms = 0.0
  let mut build_single = true
  if skip_build {
    match index_path {
      Some(p) => {
        let loaded = @moonseek.Index::load(p) catch {
          e => {
            println("cannot load index \{p}: \{e}")
            return ()
          }
        }
        idx = loaded
        docs = idx.doc_count()
        println(
          "loaded snapshot " + p + " (" + idx.doc_count().to_string() + " docs)",
        )
      }
      None => {
        println("--skip-build requires --index FILE")
        return ()
      }
    }
  } else {
    let runs = if build_runs > 0 {
      build_runs
    } else if docs <= 300000 {
      3
    } else {
      1
    }
    build_single = runs == 1
    let times : Array[Double] = []
    for run in 0..<runs {
      let t = @bench.monotonic_clock_start()
      let r = make_index(docs, vocab, run == runs - 1)
      let us = @bench.monotonic_clock_end(t)
      idx = r.0
      raw_bytes = r.1
      total_tokens = r.2
      times.push(us)
    }
    times.sort()
    let med_us = times[times.length() / 2]
    build_med_ms = us_ms(med_us)
    println(
      "build: median " +
      fmt(build_med_ms, 1) +
      " ms over " +
      runs.to_string() +
      (if build_single {
        " run (single run)"
      } else {
        " runs, range " +
        fmt(us_ms(times[0]), 1) +
        "-" +
        fmt(us_ms(times[times.length() - 1]), 1)
      }),
    )
  }
  match save_index_path {
    Some(p) => {
      @fs.write_file(p, idx.to_bytes()) catch {
        e => println("cannot write snapshot \{p}: \{e}")
      }
      println("snapshot -> " + p)
    }
    None => ()
  }
  // Deserializing builds a second full index while the first is still live.
  // Above 300k docs that doubles resident memory, so it is off by default at
  // scale and can be forced with --roundtrip.
  let do_roundtrip = force_roundtrip || (roundtrip && docs <= 300000)
  let m = measure(
    idx, docs, samples, do_roundtrip, raw_bytes, total_tokens, vocab,
  )
  let docs_per_s = if build_med_ms > 0.0 {
    docs.to_double() / (build_med_ms / 1000.0)
  } else {
    0.0
  }
  if build_med_ms > 0.0 {
    println(
      "build throughput: " +
      fmt(docs_per_s, 0) +
      " docs/s" +
      (if build_single { " (single run)" } else { " (median)" }),
    )
  }
  // ---- headline Markdown table ----
  let md_row = "| " +
    docs.to_string() +
    " | " +
    fmt(docs_per_s, 0) +
    " | " +
    fmt(us_ms(m.sel_p50), 3) +
    " | " +
    fmt(us_ms(m.sat_p50), 3) +
    " | " +
    fmt(us_ms(m.sat_p99), 3) +
    " | " +
    fmt(m.snapshot_mb, 1) +
    " |"
  println("=== headline table ===")
  println(TABLE_HEADER)
  println(TABLE_SEP)
  println(md_row)
  match out_path {
    Some(p) => {
      let existing = read_or_empty(p)
      let table = render_table(existing, md_row, docs)
      @fs.write_file(p, @utf8.encode(table)) catch {
        e => println("cannot write \{p}: \{e}")
      }
      println("table -> " + p)
    }
    None => ()
  }
  match json_path {
    Some(p) => {
      let js = render_json(
        docs, vocab, docs_per_s, m, build_med_ms, build_single,
      )
      @fs.write_file(p, @utf8.encode(js)) catch {
        e => println("cannot write \{p}: \{e}")
      }
      println("json -> " + p)
    }
    None => ()
  }
  println("wall clock: " + (@env.now() - wall0).to_string() + " ms")
  println("=== done ===")
}
