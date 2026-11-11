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
