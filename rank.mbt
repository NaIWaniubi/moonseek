///|
/// Sorted-array query evaluation.
///
/// Every posting list is doc-sorted, so a query's result can be carried as
/// two parallel arrays in ascending doc order instead of a
/// `HashMap[doc, score]`. That removes four hash probes per posting from the
/// hot path and makes And/Or/Not plain linear merges; the previous
/// map-based evaluator spent most of a saturated query inside hashing.
///
/// `DocScores` is strictly ascending in `docs` with no duplicates: the
/// invariants every operation below must preserve.

///|
/// Evaluation result: ascending docs with their accumulated scores.
pub struct DocScores {
  docs : Array[Int32]
  scores : Array[Double]
}

///|
pub fn DocScores::empty() -> DocScores {
  { docs: [], scores: [], }
}

///|
pub fn DocScores::length(self : DocScores) -> Int32 {
  self.docs.length()
}

///|
pub fn DocScores::is_empty(self : DocScores) -> Bool {
  self.docs.is_empty()
}

///|
/// Build from unsorted (doc, score) pairs: sorts by doc and sums duplicates.
pub fn DocScores::from_pairs(pairs : Array[(Int32, Double)]) -> DocScores {
  if pairs.is_empty() {
    return DocScores::empty()
  }
  pairs.sort_by(fn(a, b) {
    let c = a.0.compare(b.0)
    if c == 0 {
      a.1.compare(b.1)
    } else {
      c
    }
  })
  let docs : Array[Int32] = []
  let scores : Array[Double] = []
  for pair in pairs {
    let (doc, score) = pair
    if docs.length() > 0 && docs[docs.length() - 1] == doc {
      scores[scores.length() - 1] += score
    } else {
      docs.push(doc)
      scores.push(score)
    }
  }
  { docs, scores, }
}

///|
/// Append a posting whose doc is strictly greater than the last one.
pub fn DocScores::push(self : DocScores, doc : Int32, score : Double) -> Unit {
  self.docs.push(doc)
  self.scores.push(score)
}

///|
/// Intersection: docs in both, scores summed.
pub fn DocScores::inter(a : DocScores, b : DocScores) -> DocScores {
  let out = DocScores::empty()
  let mut i = 0
  let mut j = 0
  while i < a.docs.length() && j < b.docs.length() {
    let da = a.docs[i]
    let db = b.docs[j]
    if da == db {
      out.push(da, a.scores[i] + b.scores[j])
      i += 1
      j += 1
    } else if da < db {
      i += 1
    } else {
      j += 1
    }
  }
  out
}

///|
/// Union: every doc of either, scores summed on collision.
pub fn DocScores::union(a : DocScores, b : DocScores) -> DocScores {
  let out = DocScores::empty()
  let mut i = 0
  let mut j = 0
  while i < a.docs.length() && j < b.docs.length() {
    let da = a.docs[i]
    let db = b.docs[j]
    if da == db {
      out.push(da, a.scores[i] + b.scores[j])
      i += 1
      j += 1
    } else if da < db {
      out.push(da, a.scores[i])
      i += 1
    } else {
      out.push(db, b.scores[j])
      j += 1
    }
  }
  while i < a.docs.length() {
    out.push(a.docs[i], a.scores[i])
    i += 1
  }
  while j < b.docs.length() {
    out.push(b.docs[j], b.scores[j])
    j += 1
  }
  out
}

///|
/// Difference: docs of `a` not present in `b` (sorted set), scores kept.
pub fn DocScores::diff(a : DocScores, b : DocScores) -> DocScores {
  let out = DocScores::empty()
  let mut j = 0
  for i in 0..<a.docs.length() {
    let d = a.docs[i]
    while j < b.docs.length() && b.docs[j] < d {
      j += 1
    }
    if j < b.docs.length() && b.docs[j] == d {
      continue
    }
    out.push(d, a.scores[i])
  }
  out
}

///|
/// Docs absent from both the index's deleted set and `excluded`, scored 0.0.
/// Used for `MatchAll` and `MatchField` (pure selectors, no BM25 term).
pub fn Index::all_live_scores(
  self : Index,
  excluded : DocScores,
  keep : (Int32) -> Bool,
) -> DocScores {
  let docs : Array[Int32] = []
  let scores : Array[Double] = []
  let mut j = 0
  for num in 0..<self.doc_ids.length() {
    if self.is_deleted(num) || !keep(num) {
      continue
    }
    while j < excluded.docs.length() && excluded.docs[j] < num {
      j += 1
    }
    if j < excluded.docs.length() && excluded.docs[j] == num {
      continue
    }
    docs.push(num)
    scores.push(0.0)
  }
  { docs, scores, }
}

///|
/// Materialize a result set into `Hit`s ordered by (score desc, id asc) and
/// truncated to `limit` (0 = everything).
///
/// With a positive limit this is a bounded selection: a candidate is only
/// turned into a `Hit` (document-id lookup included) once it beats the
/// current worst of the top set, so a saturated query does not pay for
/// n string lookups.
pub fn Index::collect_hits(
  self : Index,
  scored : DocScores,
  limit : Int32,
) -> Array[Hit] {
  let n = scored.docs.length()
  if n == 0 {
    return []
  }
  if limit <= 0 || n <= limit {
    let hits : Array[Hit] = []
    for i in 0..<n {
      hits.push({ id: self.doc_ids[scored.docs[i]], score: scored.scores[i], })
    }
    hits.sort_by(fn(a, b) {
      let cmp = b.score.compare(a.score)
      if cmp == 0 {
        a.id.lexical_compare(b.id)
      } else {
        cmp
      }
    })
    return hits
  }
  // top is kept best-first; the last element is the current worst.
  let top : Array[Hit] = []
  for i in 0..<n {
    let score = scored.scores[i]
    if top.length() < limit {
      let hit : Hit = { id: self.doc_ids[scored.docs[i]], score, }
      insert_best_first(top, hit)
    } else {
      let worst = top[top.length() - 1]
      if score > worst.score {
        replace_worst(top, { id: self.doc_ids[scored.docs[i]], score, })
      } else if score == worst.score {
        let hit : Hit = { id: self.doc_ids[scored.docs[i]], score, }
        if hit_before_lex(hit, worst) {
          replace_worst(top, hit)
        }
      }
    }
  }
  top
}

///|
/// Ordering used for result ranking: higher score first, then smaller id in
/// lexicographic (not shortlex) order.
fn hit_before_lex(a : Hit, b : Hit) -> Bool {
  if a.score > b.score {
    true
  } else if a.score < b.score {
    false
  } else {
    a.id.lexical_compare(b.id) < 0
  }
}

///|
/// Insert into a best-first array of at most `limit` elements.
fn insert_best_first(top : Array[Hit], hit : Hit) -> Unit {
  let mut i = top.length() - 1
  top.push(hit)
  while i >= 0 && hit_before_lex(hit, top[i]) {
    top[i + 1] = top[i]
    i -= 1
  }
  top[i + 1] = hit
}

///|
/// Replace the worst (last) element of a best-first array and bubble the new
/// element up to its place.
fn replace_worst(top : Array[Hit], hit : Hit) -> Unit {
  let mut i = top.length() - 2
  while i >= 0 && hit_before_lex(hit, top[i]) {
    top[i + 1] = top[i]
    i -= 1
  }
  top[i + 1] = hit
}

///|
/// A block-max top-k run, with the work it did: postings scored and postings
/// skipped because their whole block could not reach the threshold. The
/// counters exist so the optimization is measured, not assumed.
pub(all) struct BlockMaxResult {
  hits : Array[Hit]
  scored : Int32
  skipped : Int32
} derive(Eq, Debug)

///|
pub extend BlockMaxResult with Eq::{equal, not_equal}

///|
pub extend BlockMaxResult with @debug.Debug::{to_repr}

///|
/// Top-k for a single term by Block-Max WAND (Ding & Suel): walk the postings in
/// doc order, and skip a whole doc block when the highest score any posting in
/// it could reach is below the current k-th best.
///
/// The bound is per block of `BLOCK_SIZE` consecutive doc numbers, taken from
/// that block's maximum term frequency and minimum document length — the score
/// rises with frequency and falls with length, so the pair dominates every
/// posting in the block. A block is skipped only when its bound is *strictly*
/// below the threshold, so a document that merely ties with the current k-th
/// best is still scored and can still win the id tiebreak: the result is
/// identical to scoring every posting, not merely close.
///
/// `field` restricts the term to one field (the common case); with None the
/// term is summed across fields, and the per-block bound is the sum of the
/// fields' bounds, which still dominates a document's total.
pub fn Index::term_topk_blockmax(
  self : Index,
  field : String?,
  term : String,
  limit : Int32,
) -> BlockMaxResult {
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  let n_docs = self.doc_ids.length()
  if limit <= 0 || n_docs == 0 || fields.is_empty() {
    return { hits: [], scored: 0, skipped: 0, }
  }
  let n_blocks = (n_docs + BLOCK_SIZE - 1) / BLOCK_SIZE
  let any_deleted = !self.deleted.is_empty()
  let ctxs : Array[Bm25Context] = []
  let lists : Array[Array[Posting]] = []
  let bounds : Array[Array[Double]] = []
  for f in fields {
    let ctx = self.bm25_context(f, term)
    ctxs.push(ctx)
    lists.push(self.postings_of(f, term))
    let stats = self.term_block_stats(f, term)
    let arr : Array[Double] = []
    for s in stats {
      arr.push(ctx.block_bound(s))
    }
    bounds.push(arr)
  }
  let curs = Array::make(fields.length(), 0)
  let top : Array[Hit] = []
  let mut scored = 0
  let mut skipped = 0
  for b in 0..<n_blocks {
    let hi = (b + 1) * BLOCK_SIZE
    let mut upper = 0.0
    for i in 0..<fields.length() {
      if b < bounds[i].length() {
        upper += bounds[i][b]
      }
    }
    // Skippable only once the top set is full: before that there is no
    // threshold to skip against.
    if top.length() >= limit && upper < top[top.length() - 1].score {
      for i in 0..<fields.length() {
        while curs[i] < lists[i].length() && lists[i][curs[i]].doc < hi {
          skipped += 1
          curs[i] += 1
        }
      }
      continue
    }
    // Score the block. Contributions are gathered across fields and summed per
    // document in sorted (doc, score) order, which is exactly the order
    // `DocScores::from_pairs` sums in — so the accumulated score is bit-for-bit
    // what the exact path produces, not just numerically close.
    let contrib : Array[(Int32, Double)] = []
    for i in 0..<fields.length() {
      let ctx = ctxs[i]
      if !ctx.valid {
        while curs[i] < lists[i].length() && lists[i][curs[i]].doc < hi {
          skipped += 1
          curs[i] += 1
        }
        continue
      }
      while curs[i] < lists[i].length() && lists[i][curs[i]].doc < hi {
        let posting = lists[i][curs[i]]
        scored += 1
        curs[i] += 1
        if any_deleted && self.deleted.contains(posting.doc) {
          continue
        }
        contrib.push((posting.doc, ctx.score(posting)))
      }
    }
    if contrib.is_empty() {
      continue
    }
    contrib.sort_by(fn(a, b2) {
      let c = a.0.compare(b2.0)
      if c == 0 {
        a.1.compare(b2.1)
      } else {
        c
      }
    })
    let mut i = 0
    while i < contrib.length() {
      let doc = contrib[i].0
      let mut sum = 0.0
      while i < contrib.length() && contrib[i].0 == doc {
        sum += contrib[i].1
        i += 1
      }
      let hit : Hit = { id: self.doc_ids[doc], score: sum, }
      if top.length() < limit {
        insert_best_first(top, hit)
      } else {
        let worst = top[top.length() - 1]
        if sum > worst.score {
          replace_worst(top, hit)
        } else if sum == worst.score && hit_before_lex(hit, worst) {
          replace_worst(top, hit)
        }
      }
    }
  }
  { hits: top, scored, skipped, }
}
