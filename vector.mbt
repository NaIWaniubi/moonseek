///|
/// Vector retrieval: kNN search with a HNSW graph, plus the fusion layer that
/// combines it with BM25.
///
/// Why this belongs in a full-text engine: a 2026 search box is expected to
/// answer both "which documents contain these words" and "which documents mean
/// this". Lexical retrieval is solved here; the semantic half needs
/// nearest-neighbour search over embeddings. moonseek stores and searches those
/// vectors itself rather than delegating to a separate vector database, so one
/// query can fuse both rankings.
///
/// The graph is HNSW (Malkov & Yashunin, 2018): a hierarchy of proximity graphs
/// with a sparse world at the top and a dense one below. Search descends
/// greedily to a good entry point, then runs a bounded beam at layer 0.

///|
/// Vectors of one field, laid out for the distance loop.
///
/// Two choices matter here. Points are stored in one flat buffer with a
/// `dim`-wide stride rather than as an array of arrays, so a distance
/// computation walks contiguous memory instead of chasing a pointer per
/// vector. And lookup is by internal doc number arithmetic rather than a hash
/// map probe: the graph search computes millions of distances, and a hash
/// lookup per distance dominated construction time when this was a
/// `HashMap[Int32, Array[Double]]`.
struct HnswPoints {
  data : Array[Double]
  dim : Int32
  slots : Int32
  /// `present[doc]` marks whether a vector exists for that doc number.
  present : Array[Bool]
}

///|
fn HnswPoints::from(
  vectors : Array[(Int32, Array[Double])],
  dim : Int32,
) -> HnswPoints {
  let mut max_doc = -1
  for (doc, _) in vectors {
    if doc > max_doc {
      max_doc = doc
    }
  }
  let slots = max_doc + 1
  let width = if dim > 0 { dim } else { 0 }
  let point_count = if slots > 0 { slots } else { 0 }
  let data = Array::make(point_count * width, 0.0)
  let present = Array::make(point_count, false)
  if width > 0 {
    for (doc, v) in vectors {
      if doc < 0 || doc >= point_count {
        continue
      }
      present[doc] = true
      let base = doc * width
      let n = if v.length() < width { v.length() } else { width }
      for i in 0..<n {
        data[base + i] = v[i]
      }
    }
  }
  { data, dim: width, slots: point_count, present }
}

///|
/// Cosine distance from the query to the point at `doc`. Returns 2.0 (maximal
/// distance in this metric) when the document has no vector.
fn HnswPoints::dist(self : HnswPoints, query : Array[Double], doc : Int32) -> Double {
  if doc < 0 || doc >= self.slots || !self.present[doc] || self.dim == 0 {
    return 2.0
  }
  let base = doc * self.dim
  let n = if query.length() < self.dim { query.length() } else { self.dim }
  let mut dot = 0.0
  let mut na = 0.0
  let mut nb = 0.0
  for i in 0..<n {
    let a = query[i]
    let b = self.data[base + i]
    dot += a * b
    na += a * a
    nb += b * b
  }
  if na == 0.0 || nb == 0.0 {
    return 2.0
  }
  1.0 - dot / (na.sqrt() * nb.sqrt())
}

///|
/// Cosine distance between two stored points, without materializing either
/// vector. `trim_edges` needs distances between many pairs of stored points;
/// copying a vector per comparison turned neighbour pruning into the dominant
/// allocation site of graph construction.
fn HnswPoints::dist_docs(self : HnswPoints, a : Int32, b : Int32) -> Double {
  if self.dim == 0 ||
    a < 0 ||
    a >= self.slots ||
    b < 0 ||
    b >= self.slots ||
    !self.present[a] ||
    !self.present[b] {
    return 2.0
  }
  let base_a = a * self.dim
  let base_b = b * self.dim
  let mut dot = 0.0
  let mut na = 0.0
  let mut nb = 0.0
  for i in 0..<self.dim {
    let x = self.data[base_a + i]
    let y = self.data[base_b + i]
    dot += x * y
    na += x * x
    nb += y * y
  }
  if na == 0.0 || nb == 0.0 {
    return 2.0
  }
  1.0 - dot / (na.sqrt() * nb.sqrt())
}

///|
/// One neighbour candidate during a graph walk.
priv struct Candidate {
  doc : Int32
  dist : Double
}

///|
/// A HNSW graph over the documents of one vector field.
///
/// Layers are flat adjacency lists. Layer 0 allows up to `m0` neighbours per
/// node; upper layers up to `m`. `entry` is where search starts, `top_layer`
/// the highest non-empty layer.
pub struct HnswGraph {
  /// Layer-0 adjacency, indexed by internal doc number.
  layer0 : Array[Array[Int32]]
  /// Upper layers: `upper[l][doc]` are the neighbours at layer l+1.
  upper : Array[Array[Array[Int32]]]
  mut entry : Int32
  mut top_layer : Int32
  /// Number of nodes inserted into the graph.
  mut len : Int32
  m : Int32
  m0 : Int32
  ef_construction : Int32
  dim : Int32
  /// Scratch for the visited set: `stamp[doc] == generation` means "visited in
  /// the current walk". Allocating a HashMap per `search_layer` call was the
  /// dominant cost of building a graph — an insert calls it once per layer, so
  /// a 5k-node build allocated ~35k maps. A generation counter avoids clearing
  /// the array between walks.
  priv stamp : Array[Int32]
  priv mut generation : Int32
}

///|
/// Deterministic RNG for level assignment. Level choice must be reproducible:
/// a graph that differs run to run makes recall measurements meaningless and a
/// failed search impossible to reproduce from a seed.
priv struct HnswRng {
  mut state : UInt64
}

///|
fn HnswRng::next(self : HnswRng) -> UInt64 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  self.state = x
  x
}

///|
/// Uniform in [0, 1).
fn HnswRng::unit(self : HnswRng) -> Double {
  (self.next() >> 11).to_double() / 9007199254740992.0
}

///|
/// HNSW level distribution: `floor(-ln(u) * mL)` with `mL = 1/ln(M)`.
/// The expected node count per level decays geometrically, which is what makes
/// the top layer a usable express lane.
fn HnswRng::level(self : HnswRng, ml : Double) -> Int32 {
  let mut u = self.unit()
  // Never feed 0 into ln(); the probability is negligible but the cost of -inf
  // is a corrupted graph.
  if u <= 0.0 {
    u = 1.0e-12
  }
  ((0.0 - @math.ln(u)) * ml).to_int()
}

///|
/// Cosine distance in [0, 2] = 1 - cosine similarity. Callers are expected to
/// pass normalized vectors; normalizing here as well means an unnormalized
/// vector degrades ranking slightly instead of letting its magnitude dominate.
fn cosine_distance(a : Array[Double], b : Array[Double]) -> Double {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let mut dot = 0.0
  let mut na = 0.0
  let mut nb = 0.0
  for i in 0..<n {
    dot += a[i] * b[i]
    na += a[i] * a[i]
    nb += b[i] * b[i]
  }
  if na == 0.0 || nb == 0.0 {
    // A zero vector has no direction; call it maximally distant rather than
    // dividing by zero.
    return 2.0
  }
  1.0 - dot / (na.sqrt() * nb.sqrt())
}

///|
/// Binary heap of candidates.
///
/// HNSW's beam search needs two queues with opposite orders: a min-heap to pop
/// the closest unexpanded candidate, and a max-heap for the bounded result set
/// (whose root is the current worst, the pruning threshold). Both were arrays
/// with sorted inserts at first, and the O(n) element shift on every insertion
/// dominated construction — a 5,000-vector build spent ~60 s of its time moving
/// `Candidate` structs. Heaps make insert O(log n) and remove the shifting
/// entirely.
///
/// `min_first` selects the order: true for the frontier, false for the results.
priv struct CandidateHeap {
  items : Array[Candidate]
  min_first : Bool
}

///|
fn CandidateHeap::new(min_first : Bool) -> CandidateHeap {
  { items: [], min_first, }
}

///|
fn CandidateHeap::length(self : CandidateHeap) -> Int32 {
  self.items.length()
}

///|
fn CandidateHeap::is_empty(self : CandidateHeap) -> Bool {
  self.items.is_empty()
}

///|
fn CandidateHeap::top(self : CandidateHeap) -> Candidate? {
  self.items.get(0)
}

///|
/// The order relation: true when `a` should sit above `b` in this heap.
fn CandidateHeap::above(self : CandidateHeap, a : Candidate, b : Candidate) -> Bool {
  if self.min_first {
    // Ties broken by doc number so heap operations stay deterministic; an
    // unstable order would make the graph (and therefore recall) run-dependent.
    a.dist < b.dist || (a.dist == b.dist && a.doc < b.doc)
  } else {
    a.dist > b.dist || (a.dist == b.dist && a.doc > b.doc)
  }
}

///|
fn CandidateHeap::push(self : CandidateHeap, c : Candidate) -> Unit {
  self.items.push(c)
  let mut i = self.items.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if self.above(self.items[i], self.items[parent]) {
      let tmp = self.items[parent]
      self.items[parent] = self.items[i]
      self.items[i] = tmp
      i = parent
    } else {
      break
    }
  }
}

///|
fn CandidateHeap::pop(self : CandidateHeap) -> Candidate? {
  if self.items.is_empty() {
    return None
  }
  let top = self.items[0]
  let last = self.items.pop().unwrap()
  if self.items.is_empty() {
    return Some(top)
  }
  self.items[0] = last
  let n = self.items.length()
  let mut i = 0
  while true {
    let l = i * 2 + 1
    let r = l + 1
    let mut best = i
    if l < n && self.above(self.items[l], self.items[best]) {
      best = l
    }
    if r < n && self.above(self.items[r], self.items[best]) {
      best = r
    }
    if best == i {
      break
    }
    let tmp = self.items[best]
    self.items[best] = self.items[i]
    self.items[i] = tmp
    i = best
  }
  Some(top)
}

///|
fn dist_to(points : HnswPoints, query : Array[Double], doc : Int32) -> Double {
  points.dist(query, doc)
}

///|
fn neighbours_at(graph : HnswGraph, doc : Int32, layer : Int32) -> Array[Int32] {
  if layer == 0 {
    if doc >= 0 && doc < graph.layer0.length() {
      return graph.layer0[doc]
    }
    return []
  }
  let l = layer - 1
  if l < 0 || l >= graph.upper.length() {
    return []
  }
  let per_layer = graph.upper[l]
  if doc >= 0 && doc < per_layer.length() {
    return per_layer[doc]
  }
  []
}

///|
/// Greedy descent at one layer: walk to the neighbour closest to the query and
/// stop when no neighbour improves. This is the "express lane" that makes
/// graph search logarithmic.
fn greedy_descend(
  graph : HnswGraph,
  points : HnswPoints,
  query : Array[Double],
  start : Int32,
  layer : Int32,
) -> Int32 {
  let mut current = start
  let mut current_dist = dist_to(points, query, current)
  let mut improved = true
  while improved {
    improved = false
    for nb in neighbours_at(graph, current, layer) {
      let d = dist_to(points, query, nb)
      if d < current_dist {
        current = nb
        current_dist = d
        improved = true
      }
    }
  }
  current
}

///|
/// Beam search at one layer (HNSW's `SEARCH-LAYER`).
///
/// `frontier` is a min-heap of nodes still to expand; `results` is a max-heap
/// bounded to `ef` holding the best found so far, so its root is the pruning
/// threshold. The walk stops when the closest unexpanded node is already worse
/// than the worst result — at that point no unexpanded node can improve the set.
fn search_layer(
  graph : HnswGraph,
  points : HnswPoints,
  query : Array[Double],
  entries : Array[Int32],
  ef : Int32,
  layer : Int32,
) -> Array[Candidate] {
  let frontier = CandidateHeap::new(true)
  let results = CandidateHeap::new(false)
  graph.generation += 1
  let gen = graph.generation
  for e in entries {
    if !mark_visited(graph, e, gen) {
      let c : Candidate = { doc: e, dist: dist_to(points, query, e), }
      frontier.push(c)
      results.push(c)
    }
  }
  while !frontier.is_empty() {
    let current = frontier.pop().unwrap()
    let worst = match results.top() {
      Some(w) => w.dist
      None => 3.0
    }
    if results.length() >= ef && current.dist > worst {
      break
    }
    for nb in neighbours_at(graph, current.doc, layer) {
      // mark_visited returns true when the node was already seen.
      if mark_visited(graph, nb, gen) {
        continue
      }
      let d = dist_to(points, query, nb)
      let worst_now = match results.top() {
        Some(w) => w.dist
        None => 3.0
      }
      if results.length() < ef || d < worst_now {
        let c : Candidate = { doc: nb, dist: d, }
        frontier.push(c)
        results.push(c)
        if results.length() > ef {
          let _ = results.pop()
        }
      }
    }
  }
  // Drain the max-heap into an ascending array.
  let out : Array[Candidate] = []
  while !results.is_empty() {
    let c = results.pop().unwrap()
    out.push(c)
  }
  let reversed : Array[Candidate] = []
  let mut i = out.length() - 1
  while i >= 0 {
    reversed.push(out[i])
    i -= 1
  }
  reversed
}

///|
/// Mark a node visited for the current walk. Returns true when it was *already*
/// visited, so call sites read as "skip if already seen".
fn mark_visited(graph : HnswGraph, doc : Int32, gen : Int32) -> Bool {
  if doc < 0 || doc >= graph.stamp.length() {
    // An out-of-range neighbour (possible only in a corrupt graph) counts as
    // already visited, which skips it instead of indexing out of bounds.
    return true
  }
  if graph.stamp[doc] == gen {
    return true
  }
  graph.stamp[doc] = gen
  false
}

///|
/// The `m` closest of the beam's results. This is the paper's
/// `SELECT-NEIGHBORS-SIMPLE`; the diversity-preserving heuristic variant gives
/// a slightly better recall/work tradeoff and is noted in the docs as a
/// possible improvement rather than claimed here.
fn select_neighbours(candidates : Array[Candidate], m : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  let cap = if candidates.length() < m { candidates.length() } else { m }
  for i in 0..<cap {
    out.push(candidates[i].doc)
  }
  out
}

///|
/// Build the graph over a vector field. `vectors` maps internal doc number to
/// its vector and must contain live documents only.
///
/// Construction follows ascending doc number, so the graph is a pure function
/// of the data plus the seed. That is what lets the recall tests assert exact
/// numbers rather than ranges.
pub fn build_hnsw(
  vectors : Array[(Int32, Array[Double])],
  dim : Int32,
  m~ : Int32 = 16,
  ef_construction~ : Int32 = 200,
  seed~ : UInt64 = 0x9E3779B97F4A7C15UL,
) -> HnswGraph {
  let points = HnswPoints::from(vectors, dim)
  let slot_count = points.slots
  let m0 = m * 2
  let rng : HnswRng = { state: seed, }
  let ml = 1.0 / @math.ln(m.to_double())
  let graph : HnswGraph = {
    layer0: Array::makei(slot_count, fn(_) { ([] : Array[Int32]) }),
    upper: [],
    entry: -1,
    top_layer: -1,
    len: 0,
    m,
    m0,
    ef_construction,
    dim,
    stamp: Array::make(slot_count, 0),
    generation: 0,
  }
  for (doc, vec) in vectors {
    let level = rng.level(ml)
    // Give this node a slot in every layer it belongs to.
    while graph.upper.length() < level {
      graph.upper.push(Array::makei(slot_count, fn(_) { ([] : Array[Int32]) }))
    }
    if graph.entry < 0 {
      graph.entry = doc
      graph.top_layer = level
      graph.len += 1
      continue
    }
    let mut ep = [graph.entry]
    let mut layer = graph.top_layer
    // Layers above this node's level: descend with a beam of 1.
    while layer > level {
      ep = [greedy_descend(graph, points, vec, ep[0], layer)]
      layer -= 1
    }
    // From its own level down to 0, beam-search and link both ways.
    let mut l = layer
    while l >= 0 {
      let found = search_layer(graph, points, vec, ep, graph.ef_construction, l)
      let cap = if l == 0 { graph.m0 } else { graph.m }
      for nb in select_neighbours(found, cap) {
        add_edge(graph, doc, nb, l)
        add_edge(graph, nb, doc, l)
        // Prune the neighbour's list by *distance to the neighbour*, not by
        // insertion order. Keeping the insertion-ordered prefix looks
        // harmless but splits the graph: a full node's list never accepts a
        // newcomer, so nodes inserted late receive no inbound edges and become
        // unreachable from the entry point. Measured effect of the bug:
        // layer-0 search from the entry explored 46 of 1000 reachable nodes
        // and recall@10 was 0.016 at every beam width.
        trim_edges(graph, nb, l, cap, points)
      }
      let next_ep : Array[Int32] = []
      for c in found {
        next_ep.push(c.doc)
      }
      ep = next_ep
      l -= 1
    }
    if level > graph.top_layer {
      graph.top_layer = level
      graph.entry = doc
    }
    graph.len += 1
  }
  graph
}

///|
fn edge_list(graph : HnswGraph, doc : Int32, layer : Int32) -> Array[Int32]? {
  if layer == 0 {
    if doc >= 0 && doc < graph.layer0.length() {
      return Some(graph.layer0[doc])
    }
    return None
  }
  let l = layer - 1
  if l < 0 || l >= graph.upper.length() {
    return None
  }
  let per_layer = graph.upper[l]
  if doc >= 0 && doc < per_layer.length() {
    Some(per_layer[doc])
  } else {
    None
  }
}

///|
fn add_edge(graph : HnswGraph, from : Int32, to : Int32, layer : Int32) -> Unit {
  match edge_list(graph, from, layer) {
    Some(list) =>
      if !list.contains(to) {
        list.push(to)
      }
    None => ()
  }
}

///|
/// Truncate an overflowed neighbour list to the `cap` *closest* neighbours of
/// `doc`.
///
/// Sorting by distance (rather than dropping the most recent edges) is what
/// keeps the graph connected: every node keeps the neighbours that are actually
/// useful to it, so a node inserted late still earns inbound edges from early
/// nodes whose lists are full.
fn trim_edges(
  graph : HnswGraph,
  doc : Int32,
  layer : Int32,
  cap : Int32,
  points : HnswPoints,
) -> Unit {
  let list = match edge_list(graph, doc, layer) {
    Some(l) => l
    None => return ()
  }
  if list.length() <= cap {
    return ()
  }
  if !points.present_at(doc) {
    // Without a vector for this node there is no basis for ordering; fall back
    // to the insertion prefix so the list still respects the cap.
    while list.length() > cap {
      let _ = list.pop()
    }
    return ()
  }
  let scored : Array[Candidate] = []
  for nb in list {
    scored.push({ doc: nb, dist: points.dist_docs(doc, nb) })
  }
  scored.sort_by(fn(a, b) {
    let cmp = a.dist.compare(b.dist)
    if cmp == 0 {
      a.doc.compare(b.doc)
    } else {
      cmp
    }
  })
  list.clear()
  for i in 0..<cap {
    list.push(scored[i].doc)
  }
}

///|
fn HnswPoints::present_at(self : HnswPoints, doc : Int32) -> Bool {
  doc >= 0 && doc < self.slots && self.present[doc]
}

///|
/// kNN search over the graph. Returns (doc, distance) pairs, closest first.
///
/// `ef` is the layer-0 beam width: larger means better recall and more work. It
/// is raised to at least `k`, since a beam narrower than the result set cannot
/// return `k` distinct results.
pub fn HnswGraph::search(
  self : HnswGraph,
  points : HnswPoints,
  query : Array[Double],
  k : Int32,
  ef~ : Int32 = 100,
) -> Array[(Int32, Double)] {
  let out : Array[(Int32, Double)] = []
  if self.entry < 0 || k <= 0 {
    return out
  }
  let beam = if ef < k { k } else { ef }
  let mut ep = [self.entry]
  let mut layer = self.top_layer
  while layer > 0 {
    ep = [greedy_descend(self, points, query, ep[0], layer)]
    layer -= 1
  }
  let found = search_layer(self, points, query, ep, beam, 0)
  let cap = if found.length() < k { found.length() } else { k }
  for i in 0..<cap {
    out.push((found[i].doc, found[i].dist))
  }
  out
}

///|
/// Number of nodes in the graph.
pub fn HnswGraph::size(self : HnswGraph) -> Int32 {
  self.len
}

///|
/// Highest populated layer (0 for a graph of a single node).
pub fn HnswGraph::max_layer(self : HnswGraph) -> Int32 {
  self.top_layer
}

///|
/// Index a vector for a document. A field's dimensionality is fixed by its
/// first vector; a later vector of a different length is rejected rather than
/// truncated, because truncation yields distances that look plausible and are
/// wrong.
pub fn Index::set_vector(
  self : Index,
  id : String,
  field : String,
  vector : Array[Double],
) -> Bool {
  let num = match self.doc_nums.get(id) {
    Some(n) if !self.deleted.contains(n) => n
    _ => return false
  }
  match self.dim.get(field) {
    Some(d) =>
      if d != vector.length() {
        return false
      }
    None => self.dim.set(field, vector.length())
  }
  let per_field = match self.vecs.get(field) {
    Some(m) => m
    None => {
      let m : @hashmap.HashMap[Int32, Array[Double]] = @hashmap.HashMap([])
      self.vecs.set(field, m)
      m
    }
  }
  per_field.set(num, vector)
  // The cached graph no longer describes the data.
  let _ = self.hnsw.remove(field)
  true
}

///|
/// Vectors of a field over live documents, ascending by doc number.
fn Index::live_vectors(self : Index, field : String) -> Array[(Int32, Array[Double])] {
  let out : Array[(Int32, Array[Double])] = []
  match self.vecs.get(field) {
    Some(per_field) =>
      for (num, v) in per_field.iter() {
        if !self.deleted.contains(num) {
          out.push((num, v))
        }
      }
    None => ()
  }
  out.sort_by(fn(a, b) { a.0.compare(b.0) })
  out
}

///|
/// Number of live indexed vectors in a field.
pub fn Index::vector_count(self : Index, field : String) -> Int32 {
  self.live_vectors(field).length()
}

///|
/// Dimensionality of a vector field, or 0 when nothing has been indexed.
pub fn Index::vector_dim(self : Index, field : String) -> Int32 {
  match self.dim.get(field) {
    Some(d) => d
    None => 0
  }
}

///|
/// The HNSW graph for a field, built on first use and cached until a mutation.
pub fn Index::hnsw_graph(self : Index, field : String) -> HnswGraph {
  match self.hnsw.get(field) {
    Some(g) => g
    None => {
      let vectors = self.live_vectors(field)
      let g = build_hnsw(vectors, self.vector_dim(field))
      self.hnsw.set(field, g)
      g
    }
  }
}

///|
/// Brute-force kNN: exact, O(n) per query. This is the reference the graph is
/// measured against, and the fallback for tiny collections where building a
/// graph costs more than it saves.
pub fn Index::knn_exact(
  self : Index,
  field : String,
  query : Array[Double],
  k : Int32,
) -> Array[(Int32, Double)] {
  let points = self.live_vectors(field)
  let scored : Array[(Int32, Double)] = []
  for (doc, v) in points {
    scored.push((doc, cosine_distance(query, v)))
  }
  scored.sort_by(fn(a, b) {
    let cmp = a.1.compare(b.1)
    if cmp == 0 {
      a.0.compare(b.0)
    } else {
      cmp
    }
  })
  let cap = if scored.length() < k { scored.length() } else { k }
  let out : Array[(Int32, Double)] = []
  for i in 0..<cap {
    out.push(scored[i])
  }
  out
}

///|
/// Document numbers returned by the graph search. Used by the recall
/// measurement, which must compare doc numbers rather than id strings.
fn Index::knn_graph_docs(
  self : Index,
  field : String,
  query : Array[Double],
  k : Int32,
  ef : Int32,
) -> Array[Int32] {
  let graph = self.hnsw_graph(field)
  let points = self.points_of(field)
  let found = graph.search(points, query, k, ef~)
  let out : Array[Int32] = []
  for (doc, _) in found {
    out.push(doc)
  }
  out
}

///|
/// The flat point store for a vector field.
fn Index::points_of(self : Index, field : String) -> HnswPoints {
  HnswPoints::from(self.live_vectors(field), self.vector_dim(field))
}

///|
/// Graph kNN, with similarity (1 - distance) so a higher score is better —
/// matching how a BM25 score reads to a caller.
pub fn Index::knn(
  self : Index,
  field : String,
  query : Array[Double],
  k : Int32,
  ef~ : Int32 = 100,
) -> Array[(String, Double)] {
  let docs = self.knn_graph_docs(field, query, k, ef)
  let points = self.points_of(field)
  let out : Array[(String, Double)] = []
  for doc in docs {
    out.push((self.doc_ids[doc], 1.0 - dist_to(points, query, doc)))
  }
  out
}

///|
/// Recall@k of the graph search against brute force over a query set. This is
/// the number that says whether an approximate index is usable: an
/// approximate index with unmeasured recall is a guess.
pub fn Index::knn_recall(
  self : Index,
  field : String,
  queries : Array[Array[Double]],
  k : Int32,
  ef~ : Int32 = 100,
) -> Double {
  if queries.is_empty() {
    return 0.0
  }
  let mut total = 0.0
  let mut count = 0.0
  for q in queries {
    let exact = self.knn_exact(field, q, k)
    let exact_ids : Array[Int32] = []
    for (doc, _) in exact {
      exact_ids.push(doc)
    }
    if exact_ids.is_empty() {
      continue
    }
    let approx = self.knn_graph_docs(field, q, k, ef)
    let mut hit = 0
    for doc in approx {
      if exact_ids.contains(doc) {
        hit += 1
      }
    }
    total += hit.to_double() / exact_ids.length().to_double()
    count += 1.0
  }
  if count == 0.0 {
    0.0
  } else {
    total / count
  }
}

///|
/// One fused hit from hybrid retrieval.
pub(all) struct HybridHit {
  id : String
  score : Double
  /// Rank in the BM25 ranking (1-based); 0 when the document did not match
  /// lexically.
  lexical_rank : Int32
  /// Rank in the vector ranking (1-based); 0 when it has no vector.
  vector_rank : Int32
} derive(Eq, Debug)

///|
pub extend HybridHit with Eq::{equal, not_equal}

///|
pub extend HybridHit with @debug.Debug::{to_repr}

///|
/// How two rankings are combined.
pub(all) enum Fusion {
  /// Reciprocal rank fusion: `sum over rankings of 1/(k + rank)` with the
  /// conventional `k = 60`. Rank-based, so it needs no score calibration
  /// between BM25 and cosine similarity — the reason it is the default.
  Rrf
  /// Weighted blend after min-max normalizing each ranking:
  /// `alpha * bm25 + (1 - alpha) * cosine`. Sensitive to outliers, since one
  /// very high BM25 score compresses everything else toward zero.
  Weighted(Double)
} derive(Eq, Debug)

///|
pub extend Fusion with Eq::{equal, not_equal}

///|
pub extend Fusion with @debug.Debug::{to_repr}

///|
/// Hybrid retrieval: BM25 and vector kNN, fused.
///
/// This is the retrieval layer a RAG pipeline wants. BM25 catches exact terms,
/// identifiers and rare words; the vector side catches paraphrases; RRF merges
/// them without requiring the two score scales to be comparable.
pub fn Index::hybrid_search(
  self : Index,
  query : String,
  vector : Array[Double],
  vector_field : String,
  limit~ : Int32 = 10,
  candidate_pool~ : Int32 = 100,
  fusion~ : Fusion = Rrf,
  ef~ : Int32 = 100,
) -> Array[HybridHit] raise QueryError {
  let lexical = self.search(query, limit=candidate_pool)
  let semantic = self.knn(vector_field, vector, candidate_pool, ef~)
  let lex_rank : @hashmap.HashMap[String, Int32] = @hashmap.HashMap([])
  let lex_score : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
  for i in 0..<lexical.length() {
    lex_rank.set(lexical[i].id, i + 1)
    lex_score.set(lexical[i].id, lexical[i].score)
  }
  let vec_rank : @hashmap.HashMap[String, Int32] = @hashmap.HashMap([])
  let vec_score : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
  for i in 0..<semantic.length() {
    vec_rank.set(semantic[i].0, i + 1)
    vec_score.set(semantic[i].0, semantic[i].1)
  }
  let all_ids : Array[String] = []
  for (id, _) in lex_rank.iter() {
    all_ids.push(id)
  }
  for (id, _) in vec_rank.iter() {
    if !lex_rank.contains(id) {
      all_ids.push(id)
    }
  }
  let (lex_lo, lex_hi) = score_range(lex_score)
  let (vec_lo, vec_hi) = score_range(vec_score)
  let hits : Array[HybridHit] = []
  for id in all_ids {
    let lr = lex_rank.get_or_default(id, 0)
    let vr = vec_rank.get_or_default(id, 0)
    let score = match fusion {
      Rrf => {
        let mut s = 0.0
        if lr > 0 {
          s += 1.0 / (60.0 + lr.to_double())
        }
        if vr > 0 {
          s += 1.0 / (60.0 + vr.to_double())
        }
        s
      }
      Weighted(alpha) => {
        let a = alpha.clamp(min=0.0, max=1.0)
        let ln = normalize(lex_score.get_or_default(id, 0.0), lex_lo, lex_hi)
        let vn = normalize(vec_score.get_or_default(id, 0.0), vec_lo, vec_hi)
        a * ln + (1.0 - a) * vn
      }
    }
    hits.push({ id, score, lexical_rank: lr, vector_rank: vr })
  }
  hits.sort_by(fn(a, b) {
    let cmp = b.score.compare(a.score)
    if cmp == 0 {
      a.id.lexical_compare(b.id)
    } else {
      cmp
    }
  })
  if limit > 0 && hits.length() > limit {
    hits[:limit].to_owned()
  } else {
    hits
  }
}

///|
fn score_range(scores : @hashmap.HashMap[String, Double]) -> (Double, Double) {
  let mut lo = 1.0e300
  let mut hi = -1.0e300
  for (_, v) in scores.iter() {
    if v < lo {
      lo = v
    }
    if v > hi {
      hi = v
    }
  }
  if lo > hi {
    (0.0, 0.0)
  } else {
    (lo, hi)
  }
}

///|
/// Min-max normalize into [0, 1]. A degenerate range (all scores equal) maps
/// everything to 1.0 rather than 0.0: those documents did match, and returning
/// zeros would let one degenerate ranking drag the fused score to zero.
fn normalize(value : Double, lo : Double, hi : Double) -> Double {
  if hi <= lo {
    return 1.0
  }
  (value - lo) / (hi - lo)
}