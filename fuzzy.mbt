///|
/// Levenshtein edit distance between two strings, counting insertions,
/// deletions and substitutions. Operates on Unicode code points (Chars),
/// so CJK and astral-plane characters each count as one character.
/// Classic DP with a single row: O(m*n) time, O(min(m,n)) space.
pub fn levenshtein(a : String, b : String) -> Int32 {
  let ac = a.to_array()
  let bc = b.to_array()
  // Keep the shorter string as the row to minimize memory.
  let (s, t) = if ac.length() <= bc.length() { (ac, bc) } else { (bc, ac) }
  let m = s.length()
  let n = t.length()
  if m == 0 {
    return n
  }
  let row : Array[Int32] = Array::makei(m + 1, fn(i) { i })
  for j in 1..<(n + 1) {
    let mut prev = row[0]
    row[0] = j
    for i in 1..<(m + 1) {
      let old = row[i]
      let cost = if s[i - 1] == t[j - 1] { 0 } else { 1 }
      row[i] = (row[i] + 1).min(row[i - 1] + 1).min(prev + cost)
      prev = old
    }
  }
  row[m]
}

///|
/// Damerau-Levenshtein distance (optimal string alignment variant):
/// like Levenshtein, but an adjacent transposition costs one edit.
/// Rolling 3-row DP: O(m*n) time, O(min(m,n)) space. The OSA restriction
/// (no substring edited more than once) matches the common "typo distance"
/// use case.
pub fn damerau_levenshtein(a : String, b : String) -> Int32 {
  bounded_damerau(a, b, 0x7FFFFFFF)
}

///|
/// Damerau-Levenshtein distance with an early exit: returns `bound + 1` as
/// soon as no cell in the current row can lead to a distance <= bound.
/// This is what makes fuzzy matching over large vocabularies fast — the
/// full-matrix version allocated m*n cells per candidate.
pub fn damerau_levenshtein_bounded(
  a : String,
  b : String,
  bound : Int32,
) -> Int32 {
  bounded_damerau(a, b, bound)
}

///|
/// Shared implementation: rolling rows prev2/prev/cur, early exit when the
/// row minimum exceeds `bound` (the true distance can only grow).
fn bounded_damerau(a : String, b : String, bound : Int32) -> Int32 {
  let ac = a.to_array()
  let bc = b.to_array()
  // Keep the shorter string as the DP row (columns) to bound memory.
  let (s, t) = if ac.length() <= bc.length() { (ac, bc) } else { (bc, ac) }
  let m = s.length()
  let n = t.length()
  if m == 0 {
    return n
  }
  if n - m > bound {
    return bound + 1
  }
  let width = m + 1
  let prev2 = Array::make(width, 0)
  let prev = Array::makei(width, fn(j) { j })
  let cur = Array::make(width, 0)
  let mut row_min = 0
  for i in 1..<(n + 1) {
    cur[0] = i
    row_min = i
    for j in 1..<(m + 1) {
      let cost = if s[j - 1] == t[i - 1] { 0 } else { 1 }
      let mut best = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost)
      if i > 1 && j > 1 && s[j - 1] == t[i - 2] && s[j - 2] == t[i - 1] {
        best = best.min(prev2[j - 2] + 1)
      }
      cur[j] = best
      if best < row_min {
        row_min = best
      }
    }
    if row_min > bound {
      return bound + 1
    }
    // Rotate rows: prev2 <- prev, prev <- cur, cur <- prev2 (reused buffer).
    for j in 0..<width {
      prev2[j] = prev[j]
      prev[j] = cur[j]
    }
  }
  prev[m]
}

///|
/// One dictionary term within the fuzzy distance bound.
pub(all) struct FuzzyMatch {
  term : String
  distance : Int32
} derive(Eq, Debug)

///|
pub extend FuzzyMatch with Eq::{equal, not_equal}

///|
pub extend FuzzyMatch with @debug.Debug::{to_repr}

///|
/// Hard cap on fuzzy edit distance (Lucene convention). Larger values are
/// clamped to 2; negative values behave as 0 (exact match only).
fn clamp_max_distance(max_distance : Int32) -> Int32 {
  max_distance.clamp(min=0, max=2)
}

///|
/// Collect the distinct dictionary terms of the requested fields
/// (None = all fields). A term present in several fields appears once.
fn Index::fuzzy_vocabulary(self : Index, field : String?) -> Array[String] {
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  let terms : Array[String] = []
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  for f in fields {
    for term in self.terms_of(f) {
      if !seen.contains(term) {
        seen.set(term, ())
        terms.push(term)
      }
    }
  }
  terms
}

///|
/// Find dictionary terms within `max_distance` edits of `term`, sorted by
/// (distance, term). Distance is Damerau-Levenshtein (adjacent transpositions
/// count as one edit, matching common typing errors). `max_distance` is
/// clamped to [0, 2]. `field` restricts the vocabulary (None = all fields).
/// Terms whose length differs by more than `max_distance` are skipped before
/// any distance computation, so cost stays linear in vocabulary size.
pub fn Index::fuzzy_terms(
  self : Index,
  term : String,
  max_distance~ : Int32 = 2,
  field~ : String? = None,
) -> Array[FuzzyMatch] {
  let bound = clamp_max_distance(max_distance)
  let query = term.to_array()
  let matches : Array[FuzzyMatch] = []
  for candidate in self.fuzzy_vocabulary(field) {
    // Length filter: edit distance is at least the length difference.
    if (candidate.to_array().length() - query.length()).abs() > bound {
      continue
    }
    // Bounded DP with early exit: most candidates stop after one row.
    let distance = if candidate == term {
      0
    } else {
      damerau_levenshtein_bounded(term, candidate, bound)
    }
    if distance <= bound {
      matches.push({ term: candidate, distance, })
    }
  }
  matches.sort_by(fn(a, b) {
    let cmp = a.distance.compare(b.distance)
    if cmp == 0 {
      a.term.compare(b.term)
    } else {
      cmp
    }
  })
  matches
}

///|
/// Fuzzy search: expand `term` to dictionary terms within `max_distance`
/// edits, evaluate each as a term query, and merge per-document scores by
/// taking the maximum (a document matching several variants is not boosted
/// for the repetition). Results are sorted by descending score, ties by id,
/// and capped at `limit` (0 = unlimited), mirroring `Index::search`.
/// Declared `raise QueryError` for API symmetry with `Index::search`; the
/// current implementation never raises.
#warnings("-unused_error_type")
pub fn Index::fuzzy_search(
  self : Index,
  term : String,
  max_distance~ : Int32 = 2,
  limit~ : Int32 = 10,
) -> Array[Hit] raise QueryError {
  let merged : @hashmap.HashMap[Int32, Double] = @hashmap.HashMap([])
  for m in self.fuzzy_terms(term, max_distance~) {
    for (doc, score) in self.eval_term(m.term, None).iter() {
      let best = merged.get_or_default(doc, 0.0)
      if score > best {
        merged.set(doc, score)
      }
    }
  }
  let hits : Array[Hit] = []
  for (doc, score) in merged.iter() {
    hits.push({ id: self.doc_ids[doc], score, })
  }
  hits.sort_by(fn(a, b) {
    let cmp = b.score.compare(a.score)
    if cmp == 0 {
      a.id.compare(b.id)
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
