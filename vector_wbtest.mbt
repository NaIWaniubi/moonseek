///|
/// HNSW vector index tests (whitebox: the graph walk and the distance function
/// are private, and testing them through the public API would only test the
/// wrapper).
///
/// The point of an approximate index is a *measured* tradeoff, so the central
/// test here is recall against brute force, not "it returns something". The
/// other tests pin the properties a graph can break silently: determinism from
/// a seed, metric sanity, insertion-order independence of the *result* (not of
/// the graph), and the guards that stop malformed input from producing
/// plausible-but-wrong distances.

///|
/// Deterministic unit vector in `dim` dimensions. Using a fixed generator keeps
/// recall numbers stable across runs and machines.
fn vec_of(seed : UInt64, dim : Int32) -> Array[Double] {
  let mut state = (seed * 0x9E3779B97F4A7C15UL) | 1UL
  let out : Array[Double] = []
  for _ in 0..<dim {
    state = state ^ (state << 13)
    state = state ^ (state >> 7)
    state = state ^ (state << 17)
    let u = (state >> 11).to_double() / 9007199254740992.0
    out.push(u * 2.0 - 1.0)
  }
  let mut norm = 0.0
  for v in out {
    norm += v * v
  }
  norm = norm.sqrt()
  if norm == 0.0 {
    return out
  }
  let normalized : Array[Double] = []
  for v in out {
    normalized.push(v / norm)
  }
  normalized
}

///|
test "cosine distance is a metric on normalized vectors" {
  let a = vec_of(1UL, 16)
  let b = vec_of(2UL, 16)
  // Identical vectors: distance 0.
  assert_true(cosine_distance(a, a).abs() < 1.0e-12)
  // Symmetric.
  assert_true((cosine_distance(a, b) - cosine_distance(b, a)).abs() < 1.0e-12)
  // Range [0, 2] for unit vectors, and positive for distinct ones.
  let d = cosine_distance(a, b)
  assert_true(d >= 0.0 && d <= 2.0)
  assert_true(d > 0.0)
}

///|
test "zero vectors do not divide by zero" {
  let zero : Array[Double] = [0.0, 0.0, 0.0]
  let a = vec_of(7UL, 3)
  let d = cosine_distance(zero, a)
  assert_true(d == 2.0)
  assert_true(!(d != d))
}

///|
/// A corpus of `n` vectors in `dim` dimensions, plus the index holding them.
fn vector_index(n : Int32, dim : Int32) -> Index {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  for i in 0..<n {
    let id = "d\{i}"
    idx.add({ id, fields: [("body", "doc \{i}")], })
    let _ = idx.set_vector(id, "emb", vec_of(i.to_uint64() + 1UL, dim))
  }
  idx
}

///|
test "graph kNN approaches brute force on a small corpus" {
  let idx = vector_index(400, 24)
  let queries : Array[Array[Double]] = []
  for q in 0..<40 {
    queries.push(vec_of(q.to_uint64() + 10000UL, 24))
  }
  let recall = idx.knn_recall("emb", queries, 10, ef=64)
  // A 400-point corpus with ef=64 should be near-exact; if this ever drops the
  // graph construction is broken, not merely approximate.
  assert_true(recall > 0.97)
  // The exact search must be exactly that.
  let exact = idx.knn_exact("emb", queries[0], 5)
  assert_eq(exact.length(), 5)
  for i in 1..<exact.length() {
    assert_true(exact[i - 1].1 <= exact[i].1)
  }
}

///|
test "recall rises with the beam width" {
  let idx = vector_index(3000, 32)
  let queries : Array[Array[Double]] = []
  for q in 0..<30 {
    queries.push(vec_of(q.to_uint64() + 777UL, 32))
  }
  // A narrow beam must be *no better* than a wide one. Asserting a strict
  // increase would make the test flaky at the top of the range where recall
  // saturates at 1.0.
  let narrow = idx.knn_recall("emb", queries, 10, ef=12)
  let wide = idx.knn_recall("emb", queries, 10, ef=200)
  assert_true(wide >= narrow)
  // And the wide beam should be genuinely good at this size.
  assert_true(wide > 0.95)
}

///|
test "graph build is deterministic for a seed" {
  let idx = vector_index(500, 16)
  let g1 = idx.hnsw_graph("emb")
  let g2 = idx.hnsw_graph("emb")
  // Cached, so identical object: the graph is not rebuilt per query.
  assert_eq(g1.size(), g2.size())
  assert_eq(g1.max_layer(), g2.max_layer())
  // Rebuild from scratch (new Index, same data) and compare structure.
  let idx2 = vector_index(500, 16)
  let g3 = idx2.hnsw_graph("emb")
  assert_eq(g1.size(), g3.size())
  assert_eq(g1.max_layer(), g3.max_layer())
  assert_eq(g1.entry, g3.entry)
}

///|
test "results are the same regardless of insertion order" {
  // The graph differs with insertion order — that is inherent to an
  // incremental structure — but the top-1 answer on a well-separated query
  // must not.
  let forward = Index::new([{ name: "body", weight: 1.0, }])
  let backward = Index::new([{ name: "body", weight: 1.0, }])
  let n = 200
  for i in 0..<n {
    let id = "d\{i}"
    forward.add({ id, fields: [("body", "doc")], })
    let _ = forward.set_vector(id, "emb", vec_of(i.to_uint64() + 1UL, 12))
  }
  let mut k = n - 1
  while k >= 0 {
    let id = "d\{k}"
    backward.add({ id, fields: [("body", "doc")], })
    let _ = backward.set_vector(id, "emb", vec_of(k.to_uint64() + 1UL, 12))
    k -= 1
  }
  // Query with one of the corpus vectors: it must be its own nearest neighbour
  // in both graphs.
  let q = vec_of(42UL, 12)
  let a = forward.knn("emb", q, 1, ef=64)
  let b = backward.knn("emb", q, 1, ef=64)
  assert_eq(a[0].0, b[0].0)
}

///|
test "vector dimensionality is fixed by the first vector" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "x")], })
  idx.add({ id: "b", fields: [("body", "y")], })
  assert_true(idx.set_vector("a", "emb", [1.0, 0.0, 0.0]))
  // Wrong length is rejected, not truncated.
  assert_true(!idx.set_vector("b", "emb", [1.0, 0.0]))
  assert_true(idx.set_vector("b", "emb", [0.0, 1.0, 0.0]))
  assert_eq(idx.vector_count("emb"), 2)
  assert_eq(idx.vector_dim("emb"), 3)
}

///|
test "set_vector rejects unknown and deleted documents" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "x")], })
  assert_true(!idx.set_vector("nope", "emb", [1.0, 0.0]))
  let _ = idx.delete("a")
  assert_true(!idx.set_vector("a", "emb", [1.0, 0.0]))
  assert_eq(idx.vector_count("emb"), 0)
}

///|
test "knn skips deleted documents" {
  let idx = vector_index(50, 8)
  let q = vec_of(10UL, 8)
  let before = idx.knn("emb", q, 5, ef=32)
  assert_eq(before.length(), 5)
  let victim = before[0].0
  let _ = idx.delete(victim)
  let after = idx.knn("emb", q, 5, ef=32)
  for (id, _) in after {
    assert_true(id != victim)
  }
  assert_eq(idx.vector_count("emb"), 49)
}

///|
test "knn on an empty field returns nothing instead of failing" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  let out = idx.knn("emb", [1.0, 0.0], 5)
  assert_eq(out.length(), 0)
  assert_eq(idx.vector_count("emb"), 0)
  assert_eq(idx.vector_dim("emb"), 0)
}

///|
test "k greater than the corpus returns the whole corpus" {
  let idx = vector_index(7, 4)
  let out = idx.knn("emb", vec_of(3UL, 4), 100, ef=64)
  assert_eq(out.length(), 7)
}

///|
test "HNSW graph shape is sane" {
  let idx = vector_index(1000, 16)
  let g = idx.hnsw_graph("emb")
  assert_eq(g.size(), 1000)
  // Every node belongs to layer 0, so entry must be a real node.
  assert_true(g.entry >= 0)
  // With mL = 1/ln(16), a 1000-node graph rarely exceeds 3 or 4 layers; a
  // runaway level assignment (e.g. -ln of a bad uniform) shows up here.
  assert_true(g.max_layer() >= 0 && g.max_layer() <= 6)
}

///|
test "hybrid search fuses lexical and vector rankings" {
  let idx = Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  // Two documents: one matches the term, one is semantically near the query
  // vector but shares no words.
  idx.add({
    id: "lexical",
    fields: [("title", "cron parser"), ("body", "cron expression parser")],
  })
  idx.add({
    id: "semantic",
    fields: [("title", "scheduler"), ("body", "schedule timing rules")],
  })
  idx.add({
    id: "other",
    fields: [("title", "image"), ("body", "png decoding")],
  })
  let _ = idx.set_vector("lexical", "emb", [1.0, 0.0, 0.0])
  let _ = idx.set_vector("semantic", "emb", [0.0, 1.0, 0.0])
  let _ = idx.set_vector("other", "emb", [0.0, 0.0, 1.0])
  // Query words hit "lexical"; the query vector is closest to "semantic".
  let fused = idx.hybrid_search("cron", [0.0, 1.0, 0.0], "emb", limit=3)
  assert_eq(fused.length(), 3)
  // Both must appear, each ranked in one of the two lists.
  let ids = fused.map(fn(h) { h.id })
  assert_true(ids.contains("lexical"))
  assert_true(ids.contains("semantic"))
  for h in fused {
    if h.id == "lexical" {
      assert_eq(h.lexical_rank, 1)
    }
    if h.id == "semantic" {
      assert_eq(h.vector_rank, 1)
    }
  }
  // "other" matches neither ranking's top spot, so it must come last.
  assert_eq(fused[fused.length() - 1].id, "other")
}

///|
test "hybrid search with RRF and weighted fusion both keep a lexical-only hit" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "alpha")], })
  idx.add({ id: "b", fields: [("body", "beta")], })
  let _ = idx.set_vector("b", "emb", [1.0, 0.0])
  // A query matching only lexically must still be returned under both fusions.
  let rrf = idx.hybrid_search("alpha", [1.0, 0.0], "emb", limit=5, fusion=Rrf)
  let weighted = idx.hybrid_search(
    "alpha",
    [1.0, 0.0],
    "emb",
    limit=5,
    fusion=Weighted(0.7),
  )
  assert_true(rrf.map(fn(h) { h.id }).contains("a"))
  assert_true(weighted.map(fn(h) { h.id }).contains("a"))
}

///|
test "hybrid search does not lose hits when there are no vectors at all" {
  let idx = Index::new([{ name: "body", weight: 1.0, }])
  idx.add({ id: "a", fields: [("body", "alpha")], })
  idx.add({ id: "b", fields: [("body", "alpha beta")], })
  // No vectors indexed: the vector side is empty and must not break fusion.
  let fused = idx.hybrid_search("alpha", [1.0, 0.0], "emb", limit=5)
  assert_eq(fused.length(), 2)
  for h in fused {
    assert_eq(h.vector_rank, 0)
    assert_true(h.lexical_rank > 0)
  }
}
