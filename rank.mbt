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
/// Offer a candidate to a best-first top-`limit` array, materializing the `Hit`
/// (with its id lookup) only when it can actually enter. A saturated query
/// scores thousands of candidates to keep ten; building a `Hit` for every one of
/// them was the same waste the bounded selection in `collect_hits` avoids.
fn offer(top : Array[Hit], score : Double, id : String, limit : Int32) -> Unit {
  if top.length() < limit {
    insert_best_first(top, { id, score, })
    return
  }
  let worst = top[top.length() - 1]
  if score > worst.score {
    replace_worst(top, { id, score, })
  } else if score == worst.score && id.lexical_compare(worst.id) < 0 {
    replace_worst(top, { id, score, })
  }
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
/// One term of a conjunction, prepared for the block-max walk: its posting list
/// per field, the BM25 context for each, and a cursor per field.
priv struct AndTerm {
  name : String
  fields : Array[String]
  ctxs : Array[Bm25Context]
  lists : Array[Array[Posting]]
  curs : Array[Int32]
}

///|
fn Index::and_term_prepare(
  self : Index,
  term : String,
  field : String?,
) -> AndTerm {
  let fields = match field {
    Some(f) => [f]
    None => self.field_names()
  }
  let ctxs : Array[Bm25Context] = []
  let lists : Array[Array[Posting]] = []
  for f in fields {
    ctxs.push(self.bm25_context(f, term))
    lists.push(self.postings_of(f, term))
  }
  { name: term, fields, ctxs, lists, curs: Array::make(fields.length(), 0), }
}

///|
/// True when the term can match nothing: every field it would be read in has
/// either no postings or no usable statistics. The exact evaluator produces an
/// empty result in that case, so a conjunction containing such a term is empty.
fn AndTerm::is_empty(self : AndTerm) -> Bool {
  for i in 0..<self.fields.length() {
    if self.ctxs[i].valid && !self.lists[i].is_empty() {
      return false
    }
  }
  true
}

///|
/// Number of postings over all fields. Only used to choose the driver: the term
/// with the fewest, so the walk crosses the shortest list.
fn AndTerm::posting_count(self : AndTerm) -> Int32 {
  let mut n = 0
  for list in self.lists {
    n += list.length()
  }
  n
}

///|
/// The smallest document number any of this term's field cursors is sitting on.
fn AndTerm::peek(self : AndTerm) -> Int32? {
  let mut best : Int32? = None
  for i in 0..<self.lists.length() {
    if self.curs[i] < self.lists[i].length() {
      let d = self.lists[i][self.curs[i]].doc
      match best {
        Some(b) => if d < b { best = Some(d) }
        None => best = Some(d)
      }
    }
  }
  best
}

///|
/// Move every field cursor past the document `peek` just returned, dropping
/// duplicate occurrences of the same document across fields.
fn AndTerm::advance(self : AndTerm) -> Unit {
  let d = match self.peek() {
    Some(d) => d
    None => return
  }
  for i in 0..<self.lists.length() {
    if self.curs[i] < self.lists[i].length() &&
      self.lists[i][self.curs[i]].doc == d {
      self.curs[i] += 1
    }
  }
}

///|
/// This term's score for document `doc`, and whether it occurs there at all.
/// Cursors only move forward, so a monotone walk over the driver costs one pass
/// per posting list overall.
///
/// A term read across several fields is the sum of its per-field scores, summed
/// in ascending-score order — exactly the order `DocScores::from_pairs` sums in,
/// so the value is bit-for-bit what the exact evaluator produces.
fn AndTerm::score_at(self : AndTerm, doc : Int32) -> (Bool, Double) {
  let contribs : Array[Double] = []
  for i in 0..<self.lists.length() {
    let list = self.lists[i]
    let mut c = self.curs[i]
    while c < list.length() && list[c].doc < doc {
      c += 1
    }
    self.curs[i] = c
    if c < list.length() && list[c].doc == doc && self.ctxs[i].valid {
      contribs.push(self.ctxs[i].score(list[c]))
    }
  }
  if contribs.is_empty() {
    return (false, 0.0)
  }
  contribs.sort_by(fn(a, b) { a.compare(b) })
  let mut sum = 0.0
  for v in contribs {
    sum += v
  }
  (true, sum)
}

///|
/// Top-k for a conjunction of terms (`a b`, `a AND b`, with each term possibly
/// field-scoped), by a leapfrog walk over the shortest term's postings plus the
/// same block-max pruning the single-term path uses.
///
/// Two things make it cheap and exact:
///
/// * **The shortest list drives.** Only documents of the most selective term can
///   be matches, so the walk visits them and asks the other terms whether they
///   occur at that document. A saturated term is never enumerated.
/// * **A block whose bound cannot reach the threshold is skipped.** The bound is
///   the sum, over the terms, of each term's own block maximum — a document in
///   the block must be in every term, so its total score cannot exceed that sum.
///   The test is strict, so a document that only ties is still scored and can
///   still win the id tiebreak.
///
/// Scores are summed in the query's term order, which is the order the exact
/// evaluator's nested intersections sum in, so the result is bit-for-bit the
/// full evaluation.
pub fn Index::and_terms_topk(
  self : Index,
  terms : Array[(String, String?)],
  limit : Int32,
) -> BlockMaxResult {
  let n_docs = self.doc_ids.length()
  if limit <= 0 || n_docs == 0 || terms.is_empty() {
    return { hits: [], scored: 0, skipped: 0, }
  }
  let prepared : Array[AndTerm] = []
  for pair in terms {
    prepared.push(self.and_term_prepare(pair.0, pair.1))
  }
  for t in prepared {
    if t.is_empty() {
      return { hits: [], scored: 0, skipped: 0, }
    }
  }
  // The most selective term drives the walk.
  let mut driver = 0
  let mut driver_count = 0
  for i in 0..<prepared.length() {
    let n = prepared[i].posting_count()
    if i == 0 || n < driver_count {
      driver = i
      driver_count = n
    }
  }
  let n_blocks = (n_docs + BLOCK_SIZE - 1) / BLOCK_SIZE
  // Per term, per field: the block statistics, hoisted so a visited block's
  // bound is a lookup rather than a map probe per term per block.
  let stats_all : Array[Array[Array[BlockStat]]] = []
  for t in prepared {
    let per_field : Array[Array[BlockStat]] = []
    for i in 0..<t.fields.length() {
      per_field.push(self.term_block_stats(t.fields[i], t.name))
    }
    stats_all.push(per_field)
  }
  let any_deleted = !self.deleted.is_empty()
  let top : Array[Hit] = []
  let mut scored = 0
  let mut skipped = 0
  let mut last_block = -1
  let mut block_upper = 0.0
  let mut done = false
  while !done {
    let d = match prepared[driver].peek() {
      None => {
        done = true
        0
      }
      Some(d) => d
    }
    if done {
      continue
    }
    let b = d / BLOCK_SIZE
    // The bound only changes when the walk enters a new block; compute it once
    // per block rather than once per driver document.
    if b != last_block {
      last_block = b
      block_upper = 0.0
      for i in 0..<prepared.length() {
        for j in 0..<prepared[i].fields.length() {
          if b < stats_all[i][j].length() && stats_all[i][j][b].max_tf > 0 {
            block_upper += prepared[i].ctxs[j].block_bound(stats_all[i][j][b])
          }
        }
      }
    }
    if top.length() >= limit &&
      b < n_blocks &&
      block_upper < top[top.length() - 1].score {
      // Every driver document in this block is dominated: skip the block.
      let hi = (b + 1) * BLOCK_SIZE
      let mut more = true
      while more {
        match prepared[driver].peek() {
          Some(dd) =>
            if dd < hi {
              prepared[driver].advance()
              skipped += 1
            } else {
              more = false
            }
          None => more = false
        }
      }
      continue
    }
    // Score the candidate against every term, then step past it.
    let mut total = 0.0
    let mut present = true
    for i in 0..<prepared.length() {
      let (ok, s) = prepared[i].score_at(d)
      if !ok {
        present = false
        break
      }
      total += s
    }
    prepared[driver].advance()
    if !present {
      continue
    }
    if any_deleted && self.deleted.contains(d) {
      continue
    }
    scored += 1
    offer(top, total, self.doc_ids[d], limit)
  }
  { hits: top, scored, skipped, }
}

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
  let stats_all : Array[Array[BlockStat]] = []
  for f in fields {
    ctxs.push(self.bm25_context(f, term))
    lists.push(self.postings_of(f, term))
    stats_all.push(self.term_block_stats(f, term))
  }
  let curs = Array::make(fields.length(), 0)
  let top : Array[Hit] = []
  let mut scored = 0
  let mut skipped = 0
  for b in 0..<n_blocks {
    let hi = (b + 1) * BLOCK_SIZE
    // Only a block some cursor is sitting in can be walked, and only fields
    // that have a posting in the block contribute to a document in it — so the
    // bound is computed per visited block instead of for all of them.
    let mut in_block = false
    for i in 0..<fields.length() {
      if curs[i] < lists[i].length() && lists[i][curs[i]].doc / BLOCK_SIZE == b {
        in_block = true
      }
    }
    if !in_block {
      continue
    }
    let mut upper = 0.0
    for i in 0..<fields.length() {
      if b < stats_all[i].length() && stats_all[i][b].max_tf > 0 {
        upper += ctxs[i].block_bound(stats_all[i][b])
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
    if fields.length() == 1 {
      // One field is the common case and needs no merge: score the block's
      // postings directly in doc order, offering each to the top set. No
      // intermediate array, and a `Hit` is built only for a candidate that
      // actually enters — the same allocation the bounded selection in
      // `collect_hits` already avoids.
      let ctx = ctxs[0]
      let list = lists[0]
      if ctx.valid {
        while curs[0] < list.length() && list[curs[0]].doc < hi {
          let posting = list[curs[0]]
          scored += 1
          curs[0] += 1
          if any_deleted && self.deleted.contains(posting.doc) {
            continue
          }
          offer(top, ctx.score(posting), self.doc_ids[posting.doc], limit)
        }
      } else {
        while curs[0] < list.length() && list[curs[0]].doc < hi {
          skipped += 1
          curs[0] += 1
        }
      }
      continue
    }
    // Several fields: a document's score is the sum of its per-field scores,
    // summed in ascending-score order — exactly the order `DocScores::from_pairs`
    // sums in, so the value is bit-for-bit what the exact path produces.
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
      offer(top, sum, self.doc_ids[doc], limit)
    }
  }
  { hits: top, scored, skipped, }
}
