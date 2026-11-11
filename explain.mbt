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
  let scored = self.eval_sorted(parsed)
  // The result is doc-ascending: binary search instead of materializing a map.
  let mut lo = 0
  let mut hi = scored.docs.length()
  let mut found : Double? = None
  while lo < hi {
    let mid = (lo + hi) / 2
    let d = scored.docs[mid]
    if d == doc_num {
      found = Some(scored.scores[mid])
      break
    } else if d < doc_num {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let total = match found {
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
  let leaves = explain_leaves(self, parsed)
  for (term, field, phrase) in leaves {
    let fields = match field {
      Some(f) => [f]
      None => self.field_names()
    }
    for field in fields {
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
            // A phrase leaf carries the phrase count as its frequency;
            // the raw posting frequency would overstate tf and make the
            // detail unreproducible against eval_phrase's score.
            let tf = match phrase {
              Some(terms) => self.phrase_count(terms, field, doc_num)
              None => posting.freq
            }
            let scored : Posting = {
              doc: posting.doc,
              freq: tf,
              positions: [],
            }
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
              tf,
              df: ctx.df,
              idf: ctx.idf,
              norm,
              score: ctx.score(scored),
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
  let leaves = explain_leaves(index, query)
  let out : Array[String] = []
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  for (term, _, _) in leaves {
    if !seen.contains(term) {
      seen.set(term, ())
      out.push(term)
    }
  }
  out
}

///|
/// One scored leaf: (term, field restriction, phrase terms?). `field` is
/// None for an all-fields leaf; `phrase_terms` is Some(all terms) when the
/// leaf's frequency is the phrase count rather than the posting frequency.
type ExplainLeaf = (String, String?, Array[String]?)

///|
/// The evaluator's scoring leaves with their field scoping, mirroring
/// `eval` exactly. Deduplication keeps the first occurrence per
/// (term, field) pair; a term appearing both scoped and unscoped stays as
/// two leaves because they score different posting sets.
fn explain_leaves(index : Index, query : Query) -> Array[ExplainLeaf] {
  let out : Array[ExplainLeaf] = []
  let seen : @hashmap.HashMap[(String, String?), Unit] = @hashmap.HashMap([])
  fn push(term : String, field : String?, phrase : Array[String]?) -> Unit {
    let key = (term, field)
    if !seen.contains(key) {
      seen.set(key, ())
      out.push((term, field, phrase))
    }
  }

  fn walk(node : Query) -> Unit {
    match node {
      Term(term, field) => push(term, field, None)
      Phrase(terms, field) =>
        if terms.length() > 0 {
          push(
            terms[0],
            field,
            if terms.length() > 1 {
              Some(terms)
            } else {
              None
            },
          )
        }
      Prefix(prefix, field) => {
        let fields = match field {
          Some(f) => [f]
          None => index.field_names()
        }
        for f in fields {
          for term in index.terms_of(f) {
            if term.has_prefix(prefix) {
              push(term, Some(f), None)
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
      MatchField(_) => ()
    }
  }
  walk(query)
  out
}
