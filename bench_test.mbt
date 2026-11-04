///|
/// Synthetic corpus generator: deterministic pseudo-documents mixing
/// English words and CJK characters, for reproducible benchmarks.
fn bench_corpus(count : Int32) -> Array[@moonseek.Document] {
  let words = [
    "search", "engine", "index", "query", "document", "language", "moonbit", "wasm",
    "compiler", "runtime", "memory", "safety", "fast", "embedded", "全文", "搜索",
    "引擎", "倒排", "索引", "分词", "排序", "算法",
  ]
  let docs : Array[@moonseek.Document] = []
  let mut seed = 42
  for i in 0..<count {
    let body : Array[String] = []
    for _ in 0..<80 {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      body.push(words[seed % words.length()])
    }
    docs.push({
      id: "doc-\{i}",
      fields: [
        ("title", "document \{i} " + words[i % words.length()]),
        ("body", body.join(" ")),
      ],
    })
  }
  docs
}

///|
test "bench index build" (it : @bench.T) {
  let docs = bench_corpus(1000)
  it.bench(fn() {
    let idx = @moonseek.Index::new([
      { name: "title", weight: 3.0, },
      { name: "body", weight: 1.0, },
    ])
    for doc in docs {
      idx.add(doc)
    }
    it.keep(idx)
  })
}

///|
test "bench search term" (it : @bench.T) {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for doc in bench_corpus(1000) {
    idx.add(doc)
  }
  it.bench(fn() { it.keep(try! idx.search("search", limit=10)) })
}

///|
test "bench search phrase" (it : @bench.T) {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for doc in bench_corpus(1000) {
    idx.add(doc)
  }
  it.bench(fn() { it.keep(try! idx.search("\"search engine\"", limit=10)) })
}

///|
test "bench snapshot roundtrip" (it : @bench.T) {
  let idx = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  for doc in bench_corpus(1000) {
    idx.add(doc)
  }
  it.bench(fn() {
    let image = idx.to_bytes()
    it.keep(try! @moonseek.Index::from_bytes(image))
  })
}
