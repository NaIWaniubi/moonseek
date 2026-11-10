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
  // 1. Index build
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  let t0 = @bench.monotonic_clock_start()
  for d in docs {
    idx.add(d)
  }
  let build_us = @bench.monotonic_clock_end(t0)
  println("index build: " + us_to_ms(build_us).to_string() + " ms")
  println(
    "  throughput: " +
    (n_docs.to_double() / (build_us / 1.0e6)).to_int().to_string() +
    " docs/s",
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
  // 2. Query latency: selective (df small) vs saturated (df ~ all docs)
  println("=== query latency (1000 iterations each) ===")
  let cases : Array[(String, String)] = [
    ("selective term (df~300)", "w4999x"),
    ("selective term (df~1k)", "w2500x"),
    ("anchor term (df~2k)", "moonbit"),
    ("saturated term (df~all)", "search"),
    ("chinese bigram", "搜索"),
    ("boolean", "search AND engine"),
    ("phrase", "\"database index\""),
    ("field-scoped", "title:rust"),
    ("prefix", "seg*"),
  ]
  for (label, q) in cases {
    let t = @bench.monotonic_clock_start()
    let mut sink = 0
    for _ in 0..<1000 {
      let hits = idx.search(q, limit=10) catch { _ => [] }
      sink += hits.length()
    }
    let e = @bench.monotonic_clock_end(t)
    println(
      "  " +
      label +
      ": " +
      us_to_ms(e / 1000.0).to_string() +
      " ms/query (hits " +
      sink.to_string() +
      ")",
    )
  }
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
    idx.set_facets("doc-\{i}", [("lang", [lang]), ("topic", [topic])])
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
