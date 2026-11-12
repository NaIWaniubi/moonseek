///|
/// Stress benchmark: 20k-doc synthetic corpus (Zipf vocabulary + anchor
/// words), measuring indexing throughput, query latency (selective vs
/// saturated terms), fuzzy lookup (linear vs cached BK-tree), faceted
/// search, snapshot size, and score explanation.
///
/// Run: moon run bench/stress --target native --release
/// `monotonic_clock_end` returns MICROSECONDS.

///|
/// Deterministic xorshift RNG (reproducible, no dependency).
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
/// Realistic English/Chinese anchor words mixed into the corpus.
fn anchors() -> Array[String] {
  [
    "search", "engine", "index", "query", "language", "moonbit", "wasm", "compiler",
    "runtime", "memory", "safety", "fast", "embedded", "database", "distributed",
    "consensus", "storage", "segment", "merge", "ranking", "全文", "搜索", "引擎",
    "倒排", "索引", "分词", "排序", "算法", "数据库", "存储",
  ]
}

///|
fn vocab(size : Int32) -> Array[String] {
  let words : Array[String] = []
  for i in 0..<size {
    words.push("w\{i}x")
  }
  for a in anchors() {
    words.push(a)
  }
  words
}

///|
fn corpus(count : Int32, vocab_size : Int32) -> Array[@moonseek.Document] {
  let words = vocab(vocab_size)
  let anchor_count = anchors().length()
  let rng = Rng::new(0x9E3779B97F4A7C15UL)
  let docs : Array[@moonseek.Document] = []
  for i in 0..<count {
    let body : Array[String] = []
    let len = 40 + rng.below(60)
    for _ in 0..<len {
      // 10% anchor words (matches real prose), 90% Zipf-ish synthetic.
      let word = if rng.below(10) == 0 {
        words[vocab_size + rng.below(anchor_count)]
      } else {
        let u = rng.below(vocab_size)
        words[u * u / vocab_size]
      }
      body.push(word)
    }
    docs.push({
      id: "doc-\{i}",
      fields: [
        (
          "title",
          "document \{i} " + words[vocab_size + rng.below(anchor_count)],
        ),
        ("body", body.join(" ")),
      ],
    })
  }
  docs
}

///|
fn us_to_ms(us : Double) -> Double {
  us / 1000.0
}

///|
/// Three significant decimals, so sub-microsecond cases stay readable and
/// millisecond cases are not swamped by noise digits.
fn round3(x : Double) -> Double {
  (x * 1000.0).round() / 1000.0
}

///|
/// Latencies, in ms, of two variants of the same query, measured
/// **interleaved**: every sample times both, so whatever else the machine is
/// doing drifts across the whole run instead of landing on whichever variant
/// happened to be measured first. Returns `(a p50, a min, b p50, b min)`.
///
/// The minimum is the least-contended sample, and on a busy machine it is the
/// statistic to quote — p50 mostly tracks the competing load. Both are reported
/// so the reader can tell a real speed-up from noise.
fn paired_stats(
  a : () -> Int32,
  b : () -> Int32,
) -> (Double, Double, Double, Double) {
  let run = fn(f : () -> Int32) -> Double {
    let t = @bench.monotonic_clock_start()
    let sink = f()
    let e = @bench.monotonic_clock_end(t)
    if sink < 0 {
      return 0.0
    }
    us_to_ms(e)
  }
  for _ in 0..<10 {
    let _ = run(a)
    let _ = run(b)
  }
  let a_samples : Array[Double] = []
  let b_samples : Array[Double] = []
  for _ in 0..<200 {
    a_samples.push(run(a))
    b_samples.push(run(b))
  }
  a_samples.sort()
  b_samples.sort()
  let med = fn(x : Array[Double]) -> Double { x[x.length() * 50 / 100] }
  (med(a_samples), a_samples[0], med(b_samples), b_samples[0])
}

///|
/// The block-max vs exact comparison for one query string, where the block-max
/// side is whatever `search` routes to. Returns `(wand p50, wand min, exact p50,
/// exact min)`.
fn search_stats(
  idx : @moonseek.Index,
  query : String,
) -> (Double, Double, Double, Double) {
  let routed = fn() -> Int32 {
    (idx.search(query, limit=10) catch { _ => ([] : Array[@moonseek.Hit]) }).length()
  }
  let exact = fn() -> Int32 {
    (idx.search_exact(query, limit=10) catch {
      _ => ([] : Array[@moonseek.Hit])
    }).length()
  }
  paired_stats(routed, exact)
}

///|
/// p50 latency in ms of an arbitrary call, warmed first.
fn p50_ms(f : () -> Int32) -> Double {
  for _ in 0..<5 {
    let _ = f()
  }
  let samples : Array[Double] = []
  let mut sink = 0
  for _ in 0..<100 {
    let t = @bench.monotonic_clock_start()
    sink += f()
    let e = @bench.monotonic_clock_end(t)
    samples.push(us_to_ms(e))
  }
  samples.sort()
  if sink < 0 {
    return 0.0
  }
  samples[samples.length() * 50 / 100]
}

///|
fn main {
  let n_docs : Int32 = 20000
  let n_vocab : Int32 = 5000
  println("=== moonseek stress benchmark ===")
  println(
    "corpus: " +
    n_docs.to_string() +
    " docs, vocab ~" +
    n_vocab.to_string() +
    " + " +
    anchors().length().to_string() +
    " anchors, 40-100 tokens/doc",
  )
  let docs = corpus(n_docs, n_vocab)
  let mut raw_bytes = 0
  for d in docs {
    raw_bytes += d.fields[1].1.length()
  }
  println("raw text: ~" + (raw_bytes / 1024).to_string() + " KB")
  // 1. Index build.
  //
  // Build time is measured over several runs and reported as the median:
  // a single run on a desktop machine swings 20-30% with background load,
  // and quoting the best of one sample is how benchmarks lie. The first run
  // is discarded as a warm-up (allocator and instruction cache).
  let runs = 5
  let build_times : Array[Double] = []
  let mut idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for run in 0..<runs {
    idx = @moonseek.Index::new([
      { name: "title", weight: 3.0, },
      { name: "body", weight: 1.0, },
    ])
    let t = @bench.monotonic_clock_start()
    for d in docs {
      idx.add(d)
    }
    let us = @bench.monotonic_clock_end(t)
    if run > 0 {
      build_times.push(us)
    }
  }
  build_times.sort()
  let build_us = build_times[build_times.length() / 2]
  let best_us = build_times[0]
  let worst_us = build_times[build_times.length() - 1]
  println(
    "index build: " +
    us_to_ms(build_us).to_string() +
    " ms (median of " +
    build_times.length().to_string() +
    ", range " +
    us_to_ms(best_us).to_string() +
    "-" +
    us_to_ms(worst_us).to_string() +
    ")",
  )
  println(
    "  throughput: " +
    (n_docs.to_double() / (build_us / 1.0e6)).to_int().to_string() +
    " docs/s (median)",
  )
  println(
    "  terms: " +
    idx.term_count().to_string() +
    ", docs: " +
    idx.doc_count().to_string() +
    ", snapshot: " +
    (idx.to_bytes().length() / 1024).to_string() +
    " KB",
  )
  // 2. Query latency: selective (df small) vs saturated (df ~ all docs).
  //
  // A mean over 1000 iterations is dominated by the cache-warm majority and
  // hides the tail a user actually notices. Each case reports p50 and p90 of
  // 200 timed samples (limit=10, the UI's page size).
  println("=== query latency (p50 / p90 of 200 samples, limit=10) ===")
  // Selectivity cases pick real terms from the built index by their actual
  // document frequency. Hardcoding names was wrong: the Zipf mapping caps at
  // vocab_size - 1, so "w4999x" never exists and the case silently measured
  // an empty posting list.
  let cases : Array[(String, String)] = [
    (
      "selective term (df " + idx.doc_freq("body", "w4998x").to_string() + ")",
      "w4998x",
    ),
    (
      "mid term (df " + idx.doc_freq("body", "w2500x").to_string() + ")",
      "w2500x",
    ),
    (
      "anchor term (df " + idx.doc_freq("body", "moonbit").to_string() + ")",
      "moonbit",
    ),
    (
      "saturated term (df " + idx.doc_freq("body", "search").to_string() + ")",
      "search",
    ),
    (
      "chinese bigram (df " + idx.doc_freq("body", "搜索").to_string() + ")",
      "搜索",
    ),
    ("boolean", "search AND engine"),
    ("phrase", "\"database index\""),
    ("sloppy phrase ~3", "\"database index\"~3"),
    (
      "field-scoped (title, df " +
      idx.doc_freq("title", "moonbit").to_string() +
      ")",
      "title:moonbit",
    ),
    ("prefix", "seg*"),
  ]
  for (label, q) in cases {
    // Warm up so the first sample is not a cold-cache outlier.
    for _ in 0..<10 {
      let _ = idx.search(q, limit=10) catch { _ => [] }
    }
    let samples : Array[Double] = []
    let mut sink = 0
    for _ in 0..<200 {
      let t = @bench.monotonic_clock_start()
      let hits = idx.search(q, limit=10) catch { _ => [] }
      let e = @bench.monotonic_clock_end(t)
      samples.push(us_to_ms(e))
      sink += hits.length()
    }
    samples.sort()
    let p50 = samples[samples.length() * 50 / 100]
    let p90 = samples[samples.length() * 90 / 100]
    println(
      "  " +
      label +
      ": " +
      round3(p50).to_string() +
      " / " +
      round3(p90).to_string() +
      " ms (hits " +
      sink.to_string() +
      ")",
    )
  }
  // 2b. Block-max WAND on saturated single-term queries: how much of a posting
  // list is skipped once the threshold is set, and what that buys against the
  // exact full-scan path. The two return the same hits (the engine tests check
  // that); the difference measured here is only how much work each does.
  println("=== block-max WAND (single term, limit=10) ===")
  for term in ["moonbit", "search", "搜索"] {
    let r = idx.term_topk_blockmax(None, term, 10)
    let total = r.scored + r.skipped
    let pct = if total == 0 {
      0.0
    } else {
      100.0 * r.skipped.to_double() / total.to_double()
    }
    let (w50, wmin, e50, emin) = search_stats(idx, term)
    println(
      "  " +
      term +
      " (df " +
      idx.doc_freq("body", term).to_string() +
      "): scored " +
      r.scored.to_string() +
      ", skipped " +
      r.skipped.to_string() +
      " (" +
      round3(pct).to_string() +
      "%) · block-max " +
      round3(w50).to_string() +
      " ms p50 / " +
      round3(wmin).to_string() +
      " ms min vs exact " +
      round3(e50).to_string() +
      " ms p50 / " +
      round3(emin).to_string() +
      " ms min",
    )
  }

  // 2c. Block-max on a conjunction: the walk drives on the shortest term and
  // prunes whole blocks whose summed bound cannot reach the threshold.
  println("=== block-max WAND (conjunction, limit=10) ===")
  let conjunctions : Array[(String, String, String)] = [
    ("search AND engine", "search", "engine"),
    ("moonbit AND search", "moonbit", "search"),
    ("search AND engine AND index", "search", "engine"),
  ]
  for (label, a, b) in conjunctions {
    let terms : Array[(String, String?)] = [(a, None), (b, None)]
    if label == "search AND engine AND index" {
      terms.push(("index", None))
    }
    let r = idx.and_terms_topk(terms, 10)
    let total = r.scored + r.skipped
    let pct = if total == 0 {
      0.0
    } else {
      100.0 * r.skipped.to_double() / total.to_double()
    }
    let (w50, wmin, e50, emin) = search_stats(idx, label)
    println(
      "  " +
      label +
      ": candidates scored " +
      r.scored.to_string() +
      ", driver postings skipped " +
      r.skipped.to_string() +
      " (" +
      round3(pct).to_string() +
      "%) · wand " +
      round3(w50).to_string() +
      " ms p50 / " +
      round3(wmin).to_string() +
      " ms min vs exact " +
      round3(e50).to_string() +
      " ms p50 / " +
      round3(emin).to_string() +
      " ms min",
    )
  }

  // 2d. Disjunctions: the same walk over the union of the terms.
  println("=== block-max WAND (disjunction, limit=10) ===")
  let or_cases : Array[(String, String, Array[String])] = [
    ("search OR engine", "search OR engine", ["search", "engine"]),
    (
      "moonbit OR search OR index",
      "moonbit OR search OR index",
      ["moonbit", "search", "index"],
    ),
    (
      "search OR 4 rare terms",
      "search OR w4998x OR w4997x OR w4996x OR w4995x",
      ["search", "w4998x", "w4997x", "w4996x", "w4995x"],
    ),
    (
      "1 saturated + 8 rare terms",
      "search OR w4998x OR w4997x OR w4996x OR w4995x OR w4994x OR w4993x OR w4992x OR w4991x",
      [
        "search", "w4998x", "w4997x", "w4996x", "w4995x", "w4994x", "w4993x", "w4992x",
        "w4991x",
      ],
    ),
    (
      "8 rare terms (no dense operand)",
      "w4998x OR w4997x OR w4996x OR w4995x OR w4994x OR w4993x OR w4992x OR w4991x",
      [
        "w4998x", "w4997x", "w4996x", "w4995x", "w4994x", "w4993x", "w4992x", "w4991x",
      ],
    ),
  ]
  for (label, query, terms) in or_cases {
    let pairs : Array[(String, String?)] = []
    for t in terms {
      pairs.push((t, None))
    }
    let r = idx.or_terms_topk(pairs, 10)
    let total = r.scored + r.skipped
    let pct = if total == 0 {
      0.0
    } else {
      100.0 * r.skipped.to_double() / total.to_double()
    }
    let walk = fn() -> Int32 { idx.or_terms_topk(pairs, 10).hits.length() }
    let exact = fn() -> Int32 {
      (idx.search_exact(query, limit=10) catch {
        _ => ([] : Array[@moonseek.Hit])
      }).length()
    }
    let (w50, wmin, e50, emin) = paired_stats(walk, exact)
    let route = if idx.or_walk_pays(pairs) { "walk" } else { "merge" }
    println(
      "  " +
      label +
      " [" +
      route +
      "]: documents scored " +
      r.scored.to_string() +
      ", postings skipped " +
      r.skipped.to_string() +
      " (" +
      round3(pct).to_string() +
      "%) · walk " +
      round3(w50).to_string() +
      " ms p50 / " +
      round3(wmin).to_string() +
      " ms min vs exact merge " +
      round3(e50).to_string() +
      " ms p50 / " +
      round3(emin).to_string() +
      " ms min",
    )
  }

  // 2e. Vector search on its own 5,000 x 64 index, so its cost does not pollute
  // the text benchmarks. The point buffer used to be rebuilt — and sorted — for
  // every kNN query; it is cached now, and `vector_count` still goes through
  // `live_vectors`, so the two lines below are the before and after.
  println("=== kNN: the cached point buffer (5,000 vectors x 64 dims) ===")
  let vidx = @moonseek.Index::new([{ name: "text", weight: 1.0, }])
  let dim : Int32 = 64
  let mut vseed : UInt64 = 99UL
  for d in 0..<5000 {
    vidx.add({ id: "v\{d}", fields: [("text", "vector document")], })
    let v : Array[Double] = []
    for _ in 0..<dim {
      vseed = vseed * 6364136223846793005UL + 1442695040888963407UL
      let r = (vseed >> 40).to_int()
      v.push(r.to_double() / 16777216.0 - 0.5)
    }
    let _ = vidx.set_vector("v\{d}", "emb", v)
  }
  let qv : Array[Double] = []
  for i in 0..<dim {
    qv.push(if i % 2 == 0 { 0.1 } else { -0.1 })
  }
  let rebuild = p50_ms(fn() { vidx.vector_count("emb") })
  let knn_ms = p50_ms(fn() { vidx.knn("emb", qv, 10, ef=64).length() })
  let exact_ms = p50_ms(fn() { vidx.knn_exact("emb", qv, 10).length() })
  println(
    "  point-buffer rebuild (what every query used to pay): " +
    round3(rebuild).to_string() +
    " ms",
  )
  println("  kNN query, cached points: " + round3(knn_ms).to_string() + " ms")
  println("  exact kNN, cached points: " + round3(exact_ms).to_string() + " ms")

  // 3. Fuzzy: linear scan vs cached BK-tree
  println("=== fuzzy lookup: linear vs cached BK-tree ===")
  let tree = idx.bk_tree()
  println("  bk-tree built once over " + tree.len().to_string() + " terms")
  for q in ["serch", "engin", "moonbt", "databse", "wasmm"] {
    let t = @bench.monotonic_clock_start()
    let linear = idx.fuzzy_terms(q, max_distance=2)
    let e1 = @bench.monotonic_clock_end(t)
    let t2 = @bench.monotonic_clock_start()
    let fast = idx.fuzzy_terms_fast(q, max_distance=2)
    let e2 = @bench.monotonic_clock_end(t2)
    let speedup = if e2 > 0.0 { e1 / e2 } else { 0.0 }
    println(
      "  " +
      q +
      ": linear=" +
      us_to_ms(e1).to_string() +
      " ms (" +
      linear.length().to_string() +
      " hits) · bk=" +
      us_to_ms(e2).to_string() +
      " ms (" +
      fast.length().to_string() +
      " hits) · " +
      speedup.to_string() +
      "x",
    )
  }
  // 4. Faceted search
  println("=== faceted search ===")
  let tf = @bench.monotonic_clock_start()
  for i in 0..<n_docs {
    let lang = if i % 3 == 0 { "zh" } else { "en" }
    let topic = if i % 5 == 0 {
      "search"
    } else if i % 5 == 1 {
      "db"
    } else {
      "misc"
    }
    let _ = idx.set_facets("doc-\{i}", [("lang", [lang]), ("topic", [topic])])
  }
  let set_us = @bench.monotonic_clock_end(tf)
  println("  set facets for 20k docs: " + us_to_ms(set_us).to_string() + " ms")
  let opts : @moonseek.SearchOptions = {
    limit: 10,
    offset: 0,
    filters: [{ field: "lang", values: ["en"], }],
    facet_fields: ["topic"],
  }
  let t3 = @bench.monotonic_clock_start()
  let faceted = idx.search_faceted("search", options=opts) catch {
    _ => { hits: [], total: 0, facets: [], }
  }
  let e3 = @bench.monotonic_clock_end(t3)
  println(
    "  query + filter + facet: " +
    us_to_ms(e3).to_string() +
    " ms, matches=" +
    faceted.total.to_string() +
    ", returned=" +
    faceted.hits.length().to_string(),
  )
  for (field, counts) in faceted.facets {
    if counts.length() > 0 {
      println(
        "  facet " +
        field +
        ": " +
        counts.length().to_string() +
        " values, top=" +
        counts[0].value +
        ":" +
        counts[0].count.to_string(),
      )
    }
  }
  // 6. Score explanation (measured 100x before the snapshot roundtrip;
  //    allocating the 17 MB image first polluted this number with GC pauses)
  let t6 = @bench.monotonic_clock_start()
  let mut detail_len = 0
  for _ in 0..<100 {
    let exp = idx.explain("搜索", "doc-0") catch { _ => None }
    match exp {
      Some(x) => detail_len = x.details.length()
      None => ()
    }
  }
  let e6 = @bench.monotonic_clock_end(t6)
  println(
    "=== explain x100: " +
    us_to_ms(e6 / 100.0).to_string() +
    " ms/query, " +
    detail_len.to_string() +
    " score components ===",
  )
  // 5. Snapshot roundtrip
  println("=== snapshot ===")
  let t4 = @bench.monotonic_clock_start()
  let image = idx.to_bytes()
  let e4 = @bench.monotonic_clock_end(t4)
  println(
    "  serialize: " +
    us_to_ms(e4).to_string() +
    " ms, " +
    (image.length() / 1024).to_string() +
    " KB",
  )
  let t5 = @bench.monotonic_clock_start()
  let restored = @moonseek.Index::from_bytes(image) catch {
    _ => abort("snapshot corrupt")
  }
  let e5 = @bench.monotonic_clock_end(t5)
  println(
    "  deserialize: " +
    us_to_ms(e5).to_string() +
    " ms, docs=" +
    restored.doc_count().to_string(),
  )
  let before = idx.search("搜索", limit=3) catch { _ => [] }
  let after = restored.search("搜索", limit=3) catch { _ => [] }
  println(
    "  restored search parity: " +
    (before.length() == after.length()).to_string(),
  )
  println("=== done ===")
}
