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
pub struct Index {
  schema : Array[FieldSchema]
  analyzer : Analyzer
  bm25 : Bm25Params
  /// field name -> term -> postings (sorted by doc)
  postings : @hashmap.HashMap[String, @hashmap.HashMap[String, Array[Posting]]]
  /// internal doc number -> external id
  doc_ids : Array[String]
  /// external id -> internal doc number
  doc_nums : @hashmap.HashMap[String, Int32]
  /// field name -> stats
  stats : @hashmap.HashMap[String, FieldStats]
  /// internal doc numbers of deleted documents
  deleted : @hashmap.HashMap[Int32, Unit]
  /// stored original field texts: internal doc number -> (field, text)
  stored : @hashmap.HashMap[Int32, Array[(String, String)]]
  /// facet values: internal doc number -> (field, values)
  facets : @hashmap.HashMap[Int32, Array[(String, Array[String])]]
  /// Cached lexicographically sorted term lists per field. Cleared on add
  /// (the only operation that introduces new terms); prefix queries reuse it
  /// instead of re-sorting the whole vocabulary.
  terms_sorted : @hashmap.HashMap[String, Array[String]]
  /// Cached BK-trees for fuzzy lookup, keyed by field name ("*" = all fields).
  /// Cleared on add. Building one tree per query was the dominant cost of
  /// fuzzy search on large vocabularies.
  bk_trees : @hashmap.HashMap[String, BkTree]
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
    bk_trees: @hashmap.HashMap([]),
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
  if !self.bk_trees.is_empty() {
    self.bk_trees.clear()
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
    // term -> positions within this field
    let term_pos : @hashmap.HashMap[String, Array[Int32]] = @hashmap.HashMap([])
    for token in tokens {
      term_pos.get_or_init(token.term, () => []).push(token.position)
    }
    for (term, positions) in term_pos.iter() {
      let list = field_map.get_or_init(term, () => [])
      list.push({ doc: num, freq: positions.length(), positions, })
    }
  }
}

///|
fn Index::delete_by_num(self : Index, num : Int32) -> Unit {
  if self.deleted.contains(num) {
    return
  }
  self.deleted.set(num, ())
  self.stored.remove(num)
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
/// Document frequency of a term in a field (0 if absent).
pub fn Index::doc_freq(self : Index, field : String, term : String) -> Int32 {
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
/// Average length of a field over live documents.
fn Index::avg_field_length(self : Index, field : String) -> Double {
  let stats = self.stats[field]
  let count = self.doc_count()
  if count == 0 {
    0.0
  } else {
    stats.total_length.to_double() / count.to_double()
  }
}

///|
/// Per-(field, term) BM25 constants, computed once and reused for every
/// posting of the term. Computing df inside the posting loop made term
/// queries O(df²) — a 5k-posting term took ~50 ms per query.
struct Bm25Context {
  k1 : Double
  b : Double
  idf : Double
  avgdl : Double
  weight : Double
  /// doc -> field length, the only per-document lookup left.
  lengths : @hashmap.HashMap[Int32, Int32]
  /// False when the term has no live postings (score is always 0).
  valid : Bool
}

///|
fn Index::bm25_context(
  self : Index,
  field : String,
  term : String,
) -> Bm25Context {
  let n = self.doc_count()
  let df = self.doc_freq(field, term)
  let stats = self.stats[field]
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
    idf,
    avgdl: self.avg_field_length(field),
    weight: self.field_weight(field),
    lengths: stats.lengths,
    valid,
  }
}

///|
fn Bm25Context::score(self : Bm25Context, posting : Posting) -> Double {
  if !self.valid {
    return 0.0
  }
  let dl = self.lengths.get_or_default(posting.doc, 0).to_double()
  let norm = if self.avgdl == 0.0 {
    1.0
  } else {
    1.0 - self.b + self.b * dl / self.avgdl
  }
  let tf = posting.freq.to_double()
  self.idf * (tf * (self.k1 + 1.0)) / (tf + self.k1 * norm) * self.weight
}

///|
/// BM25 score of one term in one field for one document (convenience
/// wrapper; hot paths use `bm25_context` to avoid recomputing df).
fn Index::bm25_score(
  self : Index,
  field : String,
  term : String,
  posting : Posting,
) -> Double {
  self.bm25_context(field, term).score(posting)
}
