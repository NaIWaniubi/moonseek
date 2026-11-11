///|
/// Retrieval-quality metrics: NDCG@k, MRR@k, Recall@k.
///
/// These are computed from the grade table built by `build_qrels`, so they
/// measure the engine's ranking against labels that were fixed in advance and
/// derived independently of the retriever.

///|
/// Discount for rank i (1-based): 1 / log2(i + 1), so rank 1 is weight 1.0.
fn rank_discount(rank : Int32) -> Double {
  1.0 / @math.log2(rank.to_double() + 1.0)
}

///|
/// Discounted cumulative gain of a ranked id list, capped at `k`.
/// `gains` maps id -> grade; an ungraded id contributes nothing.
fn dcg(
  gains : @hashmap.HashMap[String, Int32],
  ranked : Array[String],
  k : Int32,
) -> Double {
  let mut sum = 0.0
  let n = if ranked.length() < k { ranked.length() } else { k }
  for i in 0..<n {
    let grade = gains.get_or_default(ranked[i], 0).to_double()
    // 2^grade - 1 is the standard exponential gain; grade 0 gives 0.
    sum += (@math.pow(2.0, grade) - 1.0) * rank_discount(i + 1)
  }
  sum
}

///|
/// NDCG@k: DCG@k divided by the DCG of the ideal ordering of the same
/// judgments. Returns 0.0 when the query has no relevant documents (there is
/// nothing to normalize against), and 1.0 for a perfect ranking.
pub fn ndcg_at(
  gains : @hashmap.HashMap[String, Int32],
  ranked : Array[String],
  k : Int32,
) -> Double {
  let actual = dcg(gains, ranked, k)
  if actual == 0.0 {
    return 0.0
  }
  // Ideal ranking: every relevant document sorted by descending grade.
  let grades : Array[Int32] = []
  for (_, g) in gains.iter() {
    if g > 0 {
      grades.push(g)
    }
  }
  if grades.is_empty() {
    return 0.0
  }
  grades.sort_by(fn(a, b) { b.compare(a) })
  let mut ideal = 0.0
  let n = if grades.length() < k { grades.length() } else { k }
  for i in 0..<n {
    ideal += (@math.pow(2.0, grades[i].to_double()) - 1.0) *
      rank_discount(i + 1)
  }
  if ideal == 0.0 {
    0.0
  } else {
    actual / ideal
  }
}

///|
/// Reciprocal rank of the first relevant document (grade > 0), capped at `k`.
/// Returns 0.0 when nothing relevant appears within the first `k` results.
pub fn mrr_at(
  gains : @hashmap.HashMap[String, Int32],
  ranked : Array[String],
  k : Int32,
) -> Double {
  let n = if ranked.length() < k { ranked.length() } else { k }
  for i in 0..<n {
    if gains.get_or_default(ranked[i], 0) > 0 {
      return 1.0 / (i.to_double() + 1.0)
    }
  }
  0.0
}

///|
/// Recall@k: fraction of all relevant documents that appear in the first `k`
/// results. Returns 0.0 for a query with no relevant documents.
pub fn recall_at(
  gains : @hashmap.HashMap[String, Int32],
  ranked : Array[String],
  k : Int32,
) -> Double {
  let mut relevant = 0
  for (_, g) in gains.iter() {
    if g > 0 {
      relevant += 1
    }
  }
  if relevant == 0 {
    return 0.0
  }
  let n = if ranked.length() < k { ranked.length() } else { k }
  let mut found = 0
  // Count distinct relevant docs in the top k: a ranking should not repeat a
  // document, but recall must not be inflatable by duplicates either.
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  for i in 0..<n {
    let id = ranked[i]
    if seen.contains(id) {
      continue
    }
    seen.set(id, ())
    if gains.get_or_default(id, 0) > 0 {
      found += 1
    }
  }
  found.to_double() / relevant.to_double()
}
