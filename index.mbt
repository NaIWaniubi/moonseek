///|
/// A document to be indexed. `id` is caller-assigned and must be unique
/// within the index; re-adding an existing id replaces the old document.
pub(all) struct Document {
  id : String
  /// Field name -> text. Field names must be declared in the schema.
  fields : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend Document with Eq::{equal, not_equal}

///|
pub extend Document with @debug.Debug::{to_repr}

///|
/// Field schema: name + scoring weight (e.g. title=3.0, body=1.0).
pub(all) struct FieldSchema {
  name : String
  weight : Double
} derive(Eq, Debug)

///|
pub extend FieldSchema with Eq::{equal, not_equal}

///|
pub extend FieldSchema with @debug.Debug::{to_repr}

///|
/// One posting: which document, how many times, and where.
pub(all) struct Posting {
  doc : Int32
  freq : Int32
  positions : Array[Int32]
} derive(Eq, Debug)

///|
pub extend Posting with Eq::{equal, not_equal}

///|
pub extend Posting with @debug.Debug::{to_repr}

///|
/// Per-field statistics needed by BM25.
struct FieldStats {
  /// doc -> field length in tokens
  lengths : @hashmap.HashMap[Int32, Int32]
  mut total_length : Int32
}

///|
/// BM25 parameters (Robertson/Sparck Jones defaults).
pub(all) struct Bm25Params {
  k1 : Double
  b : Double
} derive(Eq, Debug)

///|
pub extend Bm25Params with Eq::{equal, not_equal}

///|
pub extend Bm25Params with @debug.Debug::{to_repr}

///|
pub fn Bm25Params::default() -> Bm25Params {
  { k1: 1.2, b: 0.75, }
}

///|
/// An in-memory inverted index over a fixed field schema.
///
/// All mutable state is private: callers reach it only through the
/// accessor methods (schema/analyzer/bm25/doc_count/search/...), never by
/// holding a shared reference to the internal tables. Exposing the
/// HashMaps would let any caller corrupt index invariants and hard-code
/// the storage layout into the package ABI.
pub struct Index {
  /// Field schema (names and weights), in declaration order.
  schema : Array[FieldSchema]
  analyzer : Analyzer
  bm25 : Bm25Params
  /// field name -> term -> postings (sorted by doc)
  priv postings : @hashmap.HashMap[
    String,
    @hashmap.HashMap[String, Array[Posting]],
  ]
  /// internal doc number -> external id
  priv doc_ids : Array[String]
  /// external id -> internal doc number
  priv doc_nums : @hashmap.HashMap[String, Int32]
  /// field name -> stats
  priv stats : @hashmap.HashMap[String, FieldStats]
  /// internal doc numbers of deleted documents
  priv deleted : @hashmap.HashMap[Int32, Unit]
  /// stored original field texts: internal doc number -> (field, text)
  priv stored : @hashmap.HashMap[Int32, Array[(String, String)]]
  /// facet values: internal doc number -> (field, values)
  priv facets : @hashmap.HashMap[Int32, Array[(String, Array[String])]]
  /// Cached lexicographically sorted term lists per field. Cleared on add
  /// (the only operation that introduces new terms); prefix queries reuse it
  /// instead of re-sorting the whole vocabulary.
  priv terms_sorted : @hashmap.HashMap[String, Array[String]]
  /// Scratch accumulator reused by `add` for term -> position gathering.
  /// Allocating a fresh HashMap per (document, field) was the single largest
  /// cost of building an index; the map is cleared and reused instead
  /// (clearing a small map is far cheaper than constructing one).
  priv scratch_pos : @hashmap.HashMap[String, Int32]
  priv scratch_terms : Array[String]
  priv scratch_poses : Array[Array[Int32]]
  /// Cached dense field-length arrays (doc number -> token count), built
  /// lazily from `stats` and invalidated whenever documents or tombstones
  /// change. Removes the last per-posting hash probe from BM25 scoring.
  priv lengths_dense : @hashmap.HashMap[String, Array[Int32]]
  /// Per-(field, term) doc-block statistics for block-max top-k: for each block
  /// of `BLOCK_SIZE` consecutive internal doc numbers, the highest BM25 impact
  /// any posting in it reaches and the raw values needed to recompute a safe
  /// bound when the scoring context changes. Built lazily, cleared on mutation
  /// like the other caches.
  priv block_stats : @hashmap.HashMap[(String, String), Array[BlockStat]]
  /// Cached BK-trees for fuzzy lookup, keyed by field name ("*" = all fields).
  /// Cleared on add. Building one tree per query was the dominant cost of
  /// fuzzy search on large vocabularies.
  priv bk_trees : @hashmap.HashMap[String, BkTree]
  /// Numeric document values: internal doc number -> (field, value).
  /// The numeric counterpart of facets: not analyzed, not scored, but
  /// filterable, sortable and aggregatable. Kept separate from the inverted
  /// index because range and statistical queries want numbers, not terms.
  priv nums : @hashmap.HashMap[Int32, Array[(String, Double)]]
  /// Dense per-field numeric columns, built lazily from `nums` and
  /// invalidated on mutation. Aggregations scan a flat array instead of
  /// probing a map per document.
  priv num_cols : @hashmap.HashMap[String, Array[Double]]
  /// Vector values per (field, doc) for kNN retrieval, and the cached HNSW
  /// graph per field. Both are cleared on mutation, like the BK-trees.
  priv vecs : @hashmap.HashMap[String, @hashmap.HashMap[Int32, Array[Double]]]
  priv hnsw : @hashmap.HashMap[String, HnswGraph]
  /// Vector dimensionality per field, fixed by the first vector indexed.
  priv dim : @hashmap.HashMap[String, Int32]
  /// Corpus statistics supplied from outside this index, for cluster search.
  ///
  /// A shard sees only its own slice of the corpus, so its local `N`, `df` and
  /// `avgdl` differ from every other shard's, and the same document scores
  /// differently depending on where it landed. A coordinator that wants one
  /// consistent ranking gathers the statistics first and hands them down; this
  /// field is where "down" lands. Unset (None) means "score with local
  /// statistics", which is the single-node case and the default for cluster
  /// search because it costs one round trip instead of two.
  priv mut external_stats : ExternalStats?
}

///|
/// Corpus-wide statistics, as a coordinator computes them.
///
/// Only the three numbers BM25 actually reads are carried: the live document
/// count, the per-(field, term) document frequency, and the per-field average
/// length. Anything else would be a statistic the scoring path does not use.
pub(all) struct ExternalStats {
  n : Int32
  /// (field, term) -> document frequency across the whole corpus.
  df : @hashmap.HashMap[(String, String), Int32]
  /// field -> average field length across the whole corpus.
  avgdl : @hashmap.HashMap[String, Double]
} derive(Eq, Debug)

///|
pub extend ExternalStats with Eq::{equal, not_equal}

///|
pub extend ExternalStats with @debug.Debug::{to_repr}

///|
pub fn ExternalStats::new(
  n : Int32,
  df~ : Array[((String, String), Int32)] = [],
  avgdl~ : Array[(String, Double)] = [],
) -> ExternalStats {
  let df_map : @hashmap.HashMap[(String, String), Int32] = @hashmap.HashMap([])
  for pair in df {
    df_map.set(pair.0, pair.1)
  }
  let avgdl_map : @hashmap.HashMap[String, Double] = @hashmap.HashMap([])
  for pair in avgdl {
    avgdl_map.set(pair.0, pair.1)
  }
  { n, df: df_map, avgdl: avgdl_map, }
}

///|
/// Install corpus-wide statistics for the next searches, or clear them with
/// None. A coordinator sets them, runs the query, and clears them; leaving them
/// installed would silently mis-score a later local query.
pub fn Index::set_external_stats(self : Index, stats : ExternalStats?) -> Unit {
  self.external_stats = stats
}

///|
/// Whether external statistics are currently installed (diagnostics).
pub fn Index::has_external_stats(self : Index) -> Bool {
  match self.external_stats {
    Some(_) => true
    None => false
  }
}

///|
/// Document count that scoring should use: the external one when a coordinator
/// supplied it, otherwise this index's own live count.
fn Index::scoring_doc_count(self : Index) -> Int32 {
  match self.external_stats {
    Some(s) => s.n
    None => self.doc_count()
  }
}

///|
/// Create an empty index. Panics on duplicate field names.
pub fn Index::new(
  schema : Array[FieldSchema],
  analyzer~ : Analyzer = Analyzer::default(),
  bm25~ : Bm25Params = Bm25Params::default(),
) -> Index {
  let postings : @hashmap.HashMap[
    String,
    @hashmap.HashMap[String, Array[Posting]],
  ] = @hashmap.HashMap([])
  let stats : @hashmap.HashMap[String, FieldStats] = @hashmap.HashMap([])
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  for field in schema {
    if seen.contains(field.name) {
      abort("duplicate field name: " + field.name)
    }
    seen.set(field.name, ())
    postings.set(field.name, @hashmap.HashMap([]))
    stats.set(field.name, { lengths: @hashmap.HashMap([]), total_length: 0, })
  }
  {
    schema,
    analyzer,
    bm25,
    postings,
    doc_ids: [],
    doc_nums: @hashmap.HashMap([]),
    stats,
    deleted: @hashmap.HashMap([]),
    stored: @hashmap.HashMap([]),
    facets: @hashmap.HashMap([]),
    terms_sorted: @hashmap.HashMap([]),
    scratch_pos: @hashmap.HashMap([]),
    scratch_terms: [],
    scratch_poses: [],
    lengths_dense: @hashmap.HashMap([]),
    block_stats: @hashmap.HashMap([]),
    bk_trees: @hashmap.HashMap([]),
    nums: @hashmap.HashMap([]),
    num_cols: @hashmap.HashMap([]),
    vecs: @hashmap.HashMap([]),
    hnsw: @hashmap.HashMap([]),
    dim: @hashmap.HashMap([]),
    external_stats: None,
  }
}

///|
fn Index::field_weight(self : Index, field : String) -> Double {
  for f in self.schema {
    if f.name == field {
      return f.weight
    }
  }
  1.0
}

///|
/// Number of live documents.
pub fn Index::doc_count(self : Index) -> Int32 {
  self.doc_ids.length() - self.deleted.length()
}

///|
/// Number of distinct terms across all fields.
pub fn Index::term_count(self : Index) -> Int32 {
  let terms : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  for _, field_map in self.postings.iter2() {
    for term, _ in field_map.iter2() {
      terms.set(term, ())
    }
  }
  terms.length()
}

///|
/// Add or replace a document. Unknown field names abort.
pub fn Index::add(self : Index, doc : Document) -> Unit {
  // New terms may appear: invalidate the sorted-term and BK-tree caches.
  // Indexing 20k docs was re-sorting only on the first prefix query, so
  // clearing here is cheap (the caches are rebuilt lazily once).
  if !self.terms_sorted.is_empty() {
    self.terms_sorted.clear()
  }
  if !self.lengths_dense.is_empty() {
    self.lengths_dense.clear()
  }
  if !self.block_stats.is_empty() {
    self.block_stats.clear()
  }
  if !self.bk_trees.is_empty() {
    self.bk_trees.clear()
  }
  if !self.num_cols.is_empty() {
    self.num_cols.clear()
  }
  if !self.hnsw.is_empty() {
    self.hnsw.clear()
  }
  match self.doc_nums.get(doc.id) {
    Some(num) => self.delete_by_num(num)
    None => ()
  }
  let num = self.doc_ids.length()
  self.doc_ids.push(doc.id)
  self.doc_nums.set(doc.id, num)
  self.stored.set(num, doc.fields)
  for (field_name, text) in doc.fields {
    let field_map = match self.postings.get(field_name) {
      Some(m) => m
      None => abort("unknown field: " + field_name)
    }
    let tokens = self.analyzer.analyze(text)
    let stats = self.stats[field_name]
    stats.lengths.set(num, tokens.length())
    stats.total_length += tokens.length()
    // term -> positions, gathered into the reusable scratch accumulator.
    // terms/poses are cleared but their inner arrays are recycled by push.
    // Keep the slot table (scratch_terms) across documents: slots are
    // reassigned and their position arrays cleared, so only scratch_pos
    // (the term -> slot map) needs clearing per field.
    self.scratch_pos.clear()
    let mut used = 0
    for token in tokens {
      let idx = match self.scratch_pos.get(token.term) {
        Some(i) => i
        None => {
          let i = used
          self.scratch_pos.set(token.term, i)
          if i < self.scratch_terms.length() {
            self.scratch_terms[i] = token.term
            // Reused slot: drop the previous document's positions.
            self.scratch_poses[i].clear()
          } else {
            self.scratch_terms.push(token.term)
            self.scratch_poses.push([])
          }
          used = i + 1
          i
        }
      }
      self.scratch_poses[idx].push(token.position)
    }
    for i in 0..<used {
      let term = self.scratch_terms[i]
      let positions = self.scratch_poses[i]
      // The posting keeps its own copy: the scratch buffer is reused by the
      // next document. One copy per (doc, term) is unavoidable, but it is a
      // plain blit instead of HashMap churn.
      let list = field_map.get_or_init(term, () => [])
      list.push({
        doc: num,
        freq: positions.length(),
        positions: positions.copy(),
      })
    }
  }
}

///|
fn Index::delete_by_num(self : Index, num : Int32) -> Unit {
  if self.deleted.contains(num) {
    return
  }
  self.deleted.set(num, ())
  if !self.lengths_dense.is_empty() {
    self.lengths_dense.clear()
  }
  if !self.block_stats.is_empty() {
    self.block_stats.clear()
  }
  self.stored.remove(num)
  // Facet values of a deleted document are dead state: keeping them
  // would serialize them into every snapshot and pin them in memory
  // (read paths filter by `deleted`, but the payload never shrinks).
  self.facets.remove(num)
  for (_, stats) in self.stats.iter() {
    match stats.lengths.remove_and_get(num) {
      Some(len) => stats.total_length -= len
      None => ()
    }
  }
}

///|
/// Delete a document by external id. Returns true if it existed.
pub fn Index::delete(self : Index, id : String) -> Bool {
  match self.doc_nums.get(id) {
    Some(num) => {
      self.delete_by_num(num)
      true
    }
    None => false
  }
}

///|
/// Look up the external id of an internal doc number.
pub fn Index::doc_id(self : Index, num : Int32) -> String? {
  self.doc_ids.get(num)
}

///|
/// Sum of analyzed token counts over every live document that carries `field`.
/// The index already maintains this as part of per-field statistics, so a
/// cluster coordinator can ask for it in O(1). Recomputing it by re-analyzing
/// every document made the two-phase distributed query an order of magnitude
/// slower than the search it was gathering statistics for.
pub fn Index::field_length_total(self : Index, field : String) -> Int32 {
  match self.stats.get(field) {
    Some(stats) => stats.total_length
    None => 0
  }
}

///|
/// Number of live documents that carry `field` (public view of the same count
/// `avg_field_length` divides by).
pub fn Index::field_doc_count(self : Index, field : String) -> Int32 {
  self.field_live_count(field)
}

///|
/// Token count of a string under this index's analyzer. Exposed because a
/// cluster coordinator needs field lengths to compute a global `avgdl`, and it
/// must count tokens the same way the index did.
pub fn Index::tokens_in(self : Index, text : String) -> Int32 {
  self.analyzer.analyze(text).length()
}

///|
/// Number of internal document slots, including deleted ones. A stable upper
/// bound for iterating `doc_id` over the index's history.
pub fn Index::slot_count(self : Index) -> Int32 {
  self.doc_ids.length()
}

///|
/// Retrieve the stored original document by external id.
/// Returns None if the id is unknown or the document was deleted.
pub fn Index::get_document(self : Index, id : String) -> Document? {
  match self.doc_nums.get(id) {
    Some(num) if !self.deleted.contains(num) =>
      match self.stored.get(num) {
        Some(fields) => Some({ id, fields, })
        None => None
      }
    _ => None
  }
}

///|
/// Retrieve one stored field's original text.
pub fn Index::get_field(self : Index, id : String, field : String) -> String? {
  match self.get_document(id) {
    Some(doc) => {
      for (name, text) in doc.fields {
        if name == field {
          return Some(text)
        }
      }
      None
    }
    None => None
  }
}

///|
/// The analyzer this index was created with.
pub fn Index::analyzer(self : Index) -> Analyzer {
  self.analyzer
}

///|
/// The field schema (names and weights), in declaration order.
pub fn Index::schema(self : Index) -> Array[FieldSchema] {
  self.schema
}

///|
/// True when the internal doc number is a tombstone.
pub fn Index::is_deleted(self : Index, num : Int32) -> Bool {
  self.deleted.contains(num)
}

///|
/// Document frequency of a term in a field (0 if absent).
pub fn Index::doc_freq(self : Index, field : String, term : String) -> Int32 {
  // Fast path: no deletions ever happened — every posting is live.
  if self.deleted.is_empty() {
    return self.postings_of(field, term).length()
  }
  // With tombstones present, only scan when the term's postings could
  // contain one; postings are doc-sorted so this is a linear walk of the
  // list (bounded by df), not a hashmap probe per element.
  let mut count = 0
  for p in self.postings_of(field, term) {
    if !self.deleted.contains(p.doc) {
      count += 1
    }
  }
  count
}

///|
/// Postings of a term in a field (empty if absent).
pub fn Index::postings_of(
  self : Index,
  field : String,
  term : String,
) -> Array[Posting] {
  match self.postings.get(field) {
    Some(m) => m.get_or_default(term, [])
    None => []
  }
}

///|
/// All terms in a field, sorted in lexicographic (dictionary) order.
///
/// Note: `String::compare` is SHORTLEX in MoonBit (compares lengths first),
/// which scatters terms sharing a prefix across the array. Prefix queries
/// need true lexicographic order to be contiguous, so this uses
/// `lexical_compare` explicitly.
///
/// The sorted list is cached and reused until the next `add`; callers must
/// treat the returned array as read-only.
pub fn Index::terms_of(self : Index, field : String) -> Array[String] {
  match self.terms_sorted.get(field) {
    Some(cached) => cached
    None => {
      let result : Array[String] = []
      match self.postings.get(field) {
        Some(m) =>
          for (term, _) in m.iter() {
            result.push(term)
          }
        None => ()
      }
      result.sort_by(fn(a, b) { a.lexical_compare(b) })
      self.terms_sorted.set(field, result)
      result
    }
  }
}

///|
/// Documents per block for the block-max top-k walk. 64 is the usual choice:
/// large enough that one extra scored posting costs little, small enough that a
/// block's maximum stays tight and skip decisions land often.
pub const BLOCK_SIZE : Int32 = 16

///|
/// One block's bound on the BM25 score of any posting in it.
///
/// `impact_max` is the maximum of the score's context-free part,
/// `tf / (tf + k1 * norm(dl))`, over the block's postings — computed once, with
/// the average document length `avgdl` recorded alongside. It is the *exact*
/// block maximum when the scoring context has the same average length, because
/// the rest of the score (`idf`, `(k1+1)`, the field weight) is constant across
/// the block. When the context differs — the `dfs` path installs corpus-wide
/// statistics — the bound is recomputed from `max_tf` and `min_dl` instead,
/// which dominates the block regardless of the average length.
priv struct BlockStat {
  max_tf : Int32
  min_dl : Int32
  impact_max : Double
  avgdl : Double
}

///|
/// Per-(field, term) block statistics: one `BlockStat` per block of
/// `BLOCK_SIZE` consecutive internal doc numbers. A block with no posting
/// stores zeros, whose bound is zero and which is therefore always skippable.
/// Computed once per term and cached; cleared on mutation with the other caches.
fn Index::term_block_stats(
  self : Index,
  field : String,
  term : String,
) -> Array[BlockStat] {
  match self.block_stats.get((field, term)) {
    Some(cached) => cached
    None => {
      let n_docs = self.doc_ids.length()
      let n_blocks = (n_docs + BLOCK_SIZE - 1) / BLOCK_SIZE
      let avgdl = self.avg_field_length(field)
      let k1 = self.bm25.k1
      let b = self.bm25.b
      // Start above any real length so the minimum is taken correctly; a whole
      // int is safe because lengths are token counts, far below it.
      let max_tf = Array::make(n_blocks, 0)
      let min_dl = Array::make(n_blocks, 2147483647)
      let impact = Array::make(n_blocks, 0.0)
      let lengths = self.field_lengths(field)
      for posting in self.postings_of(field, term) {
        let blk = posting.doc / BLOCK_SIZE
        if blk < 0 || blk >= n_blocks {
          continue
        }
        if posting.freq > max_tf[blk] {
          max_tf[blk] = posting.freq
        }
        let dl = if posting.doc < lengths.length() {
          lengths[posting.doc]
        } else {
          0
        }
        if dl < min_dl[blk] {
          min_dl[blk] = dl
        }
        let norm = if avgdl == 0.0 {
          1.0
        } else {
          1.0 - b + b * dl.to_double() / avgdl
        }
        let tf = posting.freq.to_double()
        let imp = tf / (tf + k1 * norm)
        if imp > impact[blk] {
          impact[blk] = imp
        }
      }
      let out : Array[BlockStat] = []
      for blk in 0..<n_blocks {
        let lo = if min_dl[blk] == 2147483647 { 0 } else { min_dl[blk] }
        out.push({
          max_tf: max_tf[blk],
          min_dl: lo,
          impact_max: impact[blk],
          avgdl,
        })
      }
      self.block_stats.set((field, term), out)
      out
    }
  }
}

///|
/// Dense per-field token counts indexed by internal doc number (0 when the
/// document has no content in that field). Cached until the next mutation.
/// Replaces the per-posting `HashMap` probe on the BM25 scoring path.
pub fn Index::field_lengths(self : Index, field : String) -> Array[Int32] {
  match self.lengths_dense.get(field) {
    Some(arr) => arr
    None => {
      let arr = Array::make(self.doc_ids.length(), 0)
      match self.stats.get(field) {
        Some(stats) =>
          for (num, len) in stats.lengths.iter() {
            if num >= 0 && num < arr.length() {
              arr[num] = len
            }
          }
        None => ()
      }
      self.lengths_dense.set(field, arr)
      arr
    }
  }
}

///|
/// Average length of a field over the live documents that actually carry
/// it. A document can declare the schema but omit the field, so dividing
/// by the global live count would systematically dilute avgdl and skew
/// BM25 length normalization whenever such documents exist.
fn Index::avg_field_length(self : Index, field : String) -> Double {
  let stats = self.stats[field]
  let count = self.field_live_count(field)
  if count == 0 {
    0.0
  } else {
    stats.total_length.to_double() / count.to_double()
  }
}

///|
/// Number of live documents that have analyzed content in `field`.
fn Index::field_live_count(self : Index, field : String) -> Int32 {
  let stats = match self.stats.get(field) {
    Some(s) => s
    None => return 0
  }
  // O(1). `delete_by_num` removes the document from every field's length table
  // and decrements `total_length`, so the table holds live documents only.
  //
  // This used to re-scan the table whenever tombstones existed, filtering by
  // `deleted`. That was redundant *and* quadratic in practice: `bm25_context`
  // calls it once per (field, term) per query, so a single-term query over four
  // fields walked 4 x N entries. On 200k documents deleting 10% took a
  // selective-term query from 0.021 ms to 101 ms — a 5000x regression from
  // tombstones, found by bench/scale and pinned by the tombstone test below.
  stats.lengths.length()
}

///|
/// The BM25 parameters this index was created with (for diagnostics).
pub fn Index::bm25(self : Index) -> Bm25Params {
  self.bm25
}

///|
/// Per-(field, term) BM25 constants, computed once and reused for every
/// posting of the term. Computing df inside the posting loop made term
/// queries O(df²) — a 5k-posting term took ~50 ms per query.
priv struct Bm25Context {
  k1 : Double
  b : Double
  df : Int32
  idf : Double
  avgdl : Double
  weight : Double
  /// Dense doc-number -> field length array. A HashMap probe per posting was
  /// the last hashing left on the scoring path; a dense array lookup is a
  /// single bounds-checked load.
  lengths : Array[Int32]
  /// False when the term has no live postings (score is always 0).
  valid : Bool
}

///|
fn Index::bm25_context(
  self : Index,
  field : String,
  term : String,
) -> Bm25Context {
  let n = self.scoring_doc_count()
  let mut df = self.doc_freq(field, term)
  let mut avgdl = self.avg_field_length(field)
  match self.external_stats {
    Some(stats) => {
      // A term absent from the override map falls back to the local df, which
      // is the only sane answer: the coordinator only sends terms it observed,
      // and an unobserved term has df 0 locally too.
      df = stats.df.get_or_default((field, term), df)
      avgdl = stats.avgdl.get_or_default(field, avgdl)
    }
    None => ()
  }
  let valid = df > 0 && n > 0
  let idf = if valid {
    @math.ln(
      1.0 + (n.to_double() - df.to_double() + 0.5) / (df.to_double() + 0.5),
    )
  } else {
    0.0
  }
  {
    k1: self.bm25.k1,
    b: self.bm25.b,
    df,
    idf,
    avgdl,
    weight: self.field_weight(field),
    lengths: self.field_lengths(field),
    valid,
  }
}

///|
fn Bm25Context::score(self : Bm25Context, posting : Posting) -> Double {
  if !self.valid {
    return 0.0
  }
  let dl = self.lengths[posting.doc].to_double()
  let norm = if self.avgdl == 0.0 {
    1.0
  } else {
    1.0 - self.b + self.b * dl / self.avgdl
  }
  let tf = posting.freq.to_double()
  self.idf * (tf * (self.k1 + 1.0)) / (tf + self.k1 * norm) * self.weight
}

///|
/// The block-max bound: the highest score any posting in a block can reach,
/// given the block's maximum term frequency and minimum document length. Both
/// together dominate every posting in the block, because the score increases
/// with frequency and decreases with length — so the true maximum is no greater
/// than this, and a block whose bound is below the threshold cannot contain a
/// winner. `max_tf <= 0` means the block has no posting of this term, whose
/// bound is zero.
fn Bm25Context::score_upper(
  self : Bm25Context,
  max_tf : Int32,
  min_dl : Int32,
) -> Double {
  if !self.valid || max_tf <= 0 {
    return 0.0
  }
  let norm = if self.avgdl == 0.0 {
    1.0
  } else {
    1.0 - self.b + self.b * min_dl.to_double() / self.avgdl
  }
  let tf = max_tf.to_double()
  self.idf * (tf * (self.k1 + 1.0)) / (tf + self.k1 * norm) * self.weight
}

///|
/// The block-max bound for one block: the highest score any posting in it can
/// reach. Uses the tight `impact_max` when the scoring context has the same
/// average length the block was built with — the common, local-statistics case,
/// where `impact_max` times the block's constant factors *is* the block's exact
/// maximum — and the looser `(max_tf, min_dl)` bound otherwise, which dominates
/// the block for any average length.
fn Bm25Context::block_bound(self : Bm25Context, s : BlockStat) -> Double {
  if !self.valid || s.max_tf <= 0 {
    return 0.0
  }
  let raw = if s.avgdl == self.avgdl {
    self.idf * (self.k1 + 1.0) * self.weight * s.impact_max
  } else {
    self.score_upper(s.max_tf, s.min_dl)
  }
  // Inflate by one part in 1e12. The bound is computed from factored terms
  // while a posting's score is computed as one expression, so the two can
  // disagree in the last bits — and a bound one ulp *below* a posting that ties
  // the threshold would skip a document that can still win the id tiebreak.
  // The inflation is far above accumulated rounding and far below any real
  // score difference, and it can only make a block less likely to be skipped.
  raw * (1.0 + 1.0e-12)
}

///|
pub impl Default for Bm25Params with fn default() -> Bm25Params {
  { k1: 1.2, b: 0.75, }
}
