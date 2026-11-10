///|
/// Score explanation: per-term contribution breakdown for a hit.
/// Useful for debugging relevance and building "why this result" UIs.

///|
/// One term's contribution to a document's score.
pub(all) struct ScoreDetail {
  field : String
  term : String
  /// Term frequency in this document's field.
  tf : Int32
  /// Document frequency (live docs containing the term in this field).
  df : Int32
  /// Inverse document frequency component.
  idf : Double
  /// Field length normalization factor.
  norm : Double
  /// Final weighted contribution.
  score : Double
} derive(Eq, Debug)

///|
pub extend ScoreDetail with Eq::{equal, not_equal}

///|
pub extend ScoreDetail with @debug.Debug::{to_repr}

///|
/// Full explanation for one hit.
pub(all) struct Explanation {
  id : String
  total_score : Double
  details : Array[ScoreDetail]
} derive(Eq, Debug)

///|
pub extend Explanation with Eq::{equal, not_equal}

///|
pub extend Explanation with @debug.Debug::{to_repr}

///|
/// Explain the score of a query for a specific document.
/// Returns None if the document doesn't match or doesn't exist.
pub fn Index::explain(
  self : Index,
  query : String,
  id : String,
) -> Explanation? raise QueryError {
  let doc_num = match self.doc_nums.get(id) {
    Some(n) if !self.deleted.contains(n) => n
    _ => return None
  }
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval(parsed)
  let total = match scored.get(doc_num) {
    Some(s) => s
    None => return None
  }
  // Collect per-term details by walking the query's positive terms.
  // df is computed once per (field, term) — computing it per posting made
  // explain O(df²) (4 s on a 20k-doc index).
  //
  // The term list must mirror what the evaluator actually scores: a phrase
  // is scored as its first term (with phrase frequency), and a prefix is
  // expanded to the matching dictionary terms. Using the raw query terms
  // would list contributions that are not in the total.
  let details : Array[ScoreDetail] = []
  let terms = explain_terms(self, parsed)
  for term in terms {
    for field in self.field_names() {
      let postings = self.postings_of(field, term)
      // Postings are sorted by doc: binary search for this document.
      let mut lo = 0
      let mut hi = postings.length()
      let mut found : Posting? = None
      while lo < hi {
        let mid = (lo + hi) / 2
        let d = postings[mid].doc
        if d == doc_num {
          found = Some(postings[mid])
          break
        } else if d < doc_num {
          lo = mid + 1
        } else {
          hi = mid
        }
      }
      match found {
        None => ()
        Some(posting) => {
          let ctx = self.bm25_context(field, term)
          if ctx.valid {
            let dl = self.stats[field].lengths
              .get_or_default(doc_num, 0)
              .to_double()
            let norm = if ctx.avgdl == 0.0 {
              1.0
            } else {
              1.0 - ctx.b + ctx.b * dl / ctx.avgdl
            }
            details.push({
              field,
              term,
              tf: posting.freq,
              df: ctx.df,
              idf: ctx.idf,
              norm,
              score: ctx.score(posting),
            })
          }
        }
      }
    }
  }
  Some({ id, total_score: total, details, })
}

///|
/// Sort order for search results.
pub(all) enum SortOrder {
  /// Descending BM25 score (default).
  ScoreDesc
  /// Ascending BM25 score.
  ScoreAsc
  /// Ascending document id (lexicographic).
  IdAsc
  /// Descending document id.
  IdDesc
} derive(Eq, Debug)

///|
pub extend SortOrder with Eq::{equal, not_equal}

///|
pub extend SortOrder with @debug.Debug::{to_repr}

///|
/// Search with configurable sort order.
pub fn Index::search_sorted(
  self : Index,
  query : String,
  limit~ : Int32 = 10,
  sort~ : SortOrder = ScoreDesc,
) -> Array[Hit] raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval(parsed)
  let hits : Array[Hit] = []
  for (doc, score) in scored.iter() {
    hits.push({ id: self.doc_ids[doc], score, })
  }
  hits.sort_by(fn(a, b) {
    match sort {
      ScoreDesc => {
        let cmp = b.score.compare(a.score)
        if cmp == 0 {
          a.id.lexical_compare(b.id)
        } else {
          cmp
        }
      }
      ScoreAsc => {
        let cmp = a.score.compare(b.score)
        if cmp == 0 {
          a.id.lexical_compare(b.id)
        } else {
          cmp
        }
      }
      IdAsc => a.id.lexical_compare(b.id)
      IdDesc => b.id.lexical_compare(a.id)
    }
  })
  if limit > 0 && hits.length() > limit {
    hits[:limit].to_owned()
  } else {
    hits
  }
}

///|
/// Cursor-based pagination: return hits after the given (score, id) cursor.
/// More stable than offset pagination when documents are added/removed
/// between pages. Pass the last hit's score and id from the previous page.
pub fn Index::search_after(
  self : Index,
  query : String,
  after_score~ : Double,
  after_id~ : String,
  limit~ : Int32 = 10,
) -> Array[Hit] raise QueryError {
  let all = self.search(query, limit=0)
  let results : Array[Hit] = []
  let mut past_cursor = false
  for hit in all {
    if past_cursor {
      results.push(hit)
      if limit > 0 && results.length() >= limit {
        break
      }
    } else if hit.score < after_score ||
      (hit.score == after_score && hit.id.lexical_compare(after_id) > 0) {
      past_cursor = true
      results.push(hit)
      if limit > 0 && results.length() >= limit {
        break
      }
    }
  }
  results
}

///|
/// Terms the evaluator actually scores for a query, matching `eval`:
/// Phrase contributes its first term only (phrase frequency is folded in),
/// Prefix expands to the matching dictionary terms, Not contributes only
/// its left branch.
pub fn explain_terms(index : Index, query : Query) -> Array[String] {
  let out : Array[String] = []
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  fn walk(node : Query) -> Unit {
    match node {
      Term(term, _) =>
        if !seen.contains(term) {
          seen.set(term, ())
          out.push(term)
        }
      Phrase(terms, _) =>
        if terms.length() > 0 {
          let term = terms[0]
          if !seen.contains(term) {
            seen.set(term, ())
            out.push(term)
          }
        }
      Prefix(prefix, field) => {
        let fields = match field {
          Some(f) => [f]
          None => index.field_names()
        }
        for f in fields {
          for term in index.terms_of(f) {
            if term.has_prefix(prefix) && !seen.contains(term) {
              seen.set(term, ())
              out.push(term)
            }
          }
        }
      }
      And(left, right) | Or(left, right) => {
        walk(left)
        walk(right)
      }
      Not(left, _) => walk(left)
      MatchAll => ()
    }
  }
  walk(query)
  out
}
