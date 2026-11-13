///|
/// Query-shape benchmark: the cost of the compound query forms (exact phrase,
/// sloppy phrase, prefix expansion, boolean) against the single terms they are
/// built from, on the same 20k-document corpus the stress benchmark uses (same
/// generator, same seed, so the two agree).
///
/// Run: moon run bench/query --target native --release
///
/// The point is the *ratio*. A phrase is verified by walking the rarest term's
/// documents and probing the others, so it should cost on the order of that
/// term's postings, not of the sum of every term's; prefix expansion merges the
/// matching terms' doc-sorted lists instead of sorting their union. Both claims
/// are checked here. It reports p50/p90 and the minimum, like the stress bench.

///|
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
/// Identical to `bench/stress/main.mbt`'s generator: seeded xorshift, Zipf-ish
/// vocabulary and the same anchor words, so measurements are comparable.
fn corpus(count : Int32, vocab_size : Int32) -> Array[@moonseek.Document] {
  let words = vocab(vocab_size)
  let anchor_count = anchors().length()
  let rng = Rng::new(0x9E3779B97F4A7C15UL)
  let docs : Array[@moonseek.Document] = []
  for i in 0..<count {
    let body : Array[String] = []
    let len = 40 + rng.below(60)
    for _ in 0..<len {
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
fn round3(x : Double) -> Double {
  (x * 1000.0).round() / 1000.0
}

///|
/// p50, p90 and the minimum of 200 samples, all in ms.
fn percentiles(f : () -> Int32) -> (Double, Double, Double) {
  for _ in 0..<10 {
    let _ = f()
  }
  let samples : Array[Double] = []
  let mut sink = 0
  for _ in 0..<200 {
    let t = @bench.monotonic_clock_start()
    sink += f()
    let e = @bench.monotonic_clock_end(t)
    samples.push(us_to_ms(e))
  }
  samples.sort()
  let p50 = samples[samples.length() * 50 / 100]
  let p90 = samples[samples.length() * 90 / 100]
  if sink < 0 {
    return (p50, p90, samples[0])
  }
  (p50, p90, samples[0])
}

///|
fn main {
  let n_docs : Int32 = 20000
  let n_vocab : Int32 = 5000
  println("=== phrase benchmark (20k docs, limit=10) ===")
  let docs = corpus(n_docs, n_vocab)
  // One build: this harness measures queries, not indexing throughput (the
  // stress bench does that with repeats and a median).
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for d in docs {
    idx.add(d)
  }
  println(
    "index: " +
    idx.doc_count().to_string() +
    " docs, " +
    idx.term_count().to_string() +
    " terms",
  )
  // The compound cases name their terms so the df of each is printed: a phrase
  // whose rarest term is rare should cost about that term's postings, which is
  // the claim this harness exists to check.
  let cases : Array[(String, String, Array[String])] = [
    ("exact phrase, 2 saturated", "\"search engine\"", ["search", "engine"]),
    (
      "exact phrase, 3 saturated",
      "\"search engine index\"",
      ["search", "engine", "index"],
    ),
    (
      "sloppy phrase ~3, 2 saturated",
      "\"search engine\"~3",
      ["search", "engine"],
    ),
    ("exact phrase, dense + rare", "\"search w4998x\"", ["search", "w4998x"]),
    ("exact phrase, rare pair", "\"w4998x w4995x\"", ["w4998x", "w4995x"]),
    ("exact phrase, chinese", "\"搜索 引擎\"", ["搜索", "引擎"]),
    ("prefix seg*", "seg*", ["(prefix) seg"]),
    ("prefix w49*", "w49*", ["(prefix) w49"]),
    ("boolean AND, 2 saturated", "search AND engine", ["search", "engine"]),
    (
      "boolean AND, 3 saturated",
      "search AND engine AND index",
      ["search", "engine", "index"],
    ),
  ]
  for (label, query, terms) in cases {
    let dfs : Array[String] = []
    for t in terms {
      if !t.has_prefix("(prefix) ") {
        dfs.push(t + "=" + idx.doc_freq("body", t).to_string())
      }
    }
    let (p50, p90, min) = percentiles(fn() {
      let hits = idx.search(query, limit=10) catch { _ => [] }
      hits.length()
    })
    println(
      "  " +
      label +
      " (" +
      dfs.join(", ") +
      "): " +
      round3(p50).to_string() +
      " ms p50 / " +
      round3(p90).to_string() +
      " ms p90 / " +
      round3(min).to_string() +
      " ms min",
    )
  }
  // The baseline the ratios are against: the rarest term alone.
  for t in ["w4998x", "search"] {
    let (p50, _, min) = percentiles(fn() {
      let hits = idx.search(t, limit=10) catch { _ => [] }
      hits.length()
    })
    println(
      "  single " +
      t +
      " (df " +
      idx.doc_freq("body", t).to_string() +
      "): " +
      round3(p50).to_string() +
      " ms p50 / " +
      round3(min).to_string() +
      " ms min",
    )
  }
  println("=== done ===")
}
