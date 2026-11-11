///|
/// Numeric document values and aggregations.
///
/// Facets are exact-match string bags; numeric values are their numeric
/// counterpart. They are not analyzed and not scored — they exist to be
/// filtered, sorted by, and aggregated. A search service needs all three:
/// "packages published after 2025 with more than 10 releases, grouped by
/// licence, with the average release count per year" is four aggregations
/// and one range filter over the same result set.

///|
/// One aggregation request.
pub(all) enum AggSpec {
  /// Bucket by exact value of a facet field; `size` caps the buckets
  /// (0 = all). Buckets are returned by descending count.
  TermsAgg(String, Int32)
  /// count / min / max / avg / sum over a numeric field.
  StatsAgg(String)
  /// Fixed-width numeric buckets: `[k*interval, (k+1)*interval)`.
  HistogramAgg(String, Double)
  /// Linearly interpolated percentiles of a numeric field.
  PercentilesAgg(String, Array[Double])
} derive(Eq, Debug)

///|
pub extend AggSpec with Eq::{equal, not_equal}

///|
pub extend AggSpec with @debug.Debug::{to_repr}

///|
/// Descriptive statistics over one numeric field of a result set.
pub(all) struct StatSummary {
  count : Int32
  min : Double
  max : Double
  avg : Double
  sum : Double
} derive(Eq, Debug)

///|
pub extend StatSummary with Eq::{equal, not_equal}

///|
pub extend StatSummary with @debug.Debug::{to_repr}

///|
/// The result of one aggregation. Exactly one of `buckets` / `stats` /
/// `percentiles` is populated, according to the spec that produced it; the
/// unused fields are empty rather than absent so serialization stays uniform.
pub(all) struct AggResult {
  /// The field aggregated (for labelling).
  field : String
  /// What kind of aggregation produced this (for labelling).
  kind : String
  /// Bucket label -> value. For terms: doc count. For histogram: count.
  buckets : Array[(String, Double)]
  stats : StatSummary?
  /// Requested percentile -> value.
  percentiles : Array[(Double, Double)]
} derive(Eq, Debug)

///|
pub extend AggResult with Eq::{equal, not_equal}

///|
pub extend AggResult with @debug.Debug::{to_repr}

///|
/// Attach a numeric value to a document (replaces any previous value for the
/// same field). Returns false when the document does not exist or is deleted.
/// Unlike text fields, numeric fields need no schema declaration — the same
/// choice facets make, for the same reason: a search service rarely knows its
/// numeric facets at compile time.
pub fn Index::set_num(self : Index, id : String, field : String, value : Double) -> Bool {
  match self.doc_nums.get(id) {
    Some(num) if !self.deleted.contains(num) => {
      let entries : Array[(String, Double)] = match self.nums.get(num) {
        Some(existing) => {
          let out : Array[(String, Double)] = []
          for (name, v) in existing {
            if name != field {
              out.push((name, v))
            }
          }
          out
        }
        None => []
      }
      entries.push((field, value))
      self.nums.set(num, entries)
      if !self.num_cols.is_empty() {
        self.num_cols.clear()
      }
      true
    }
    _ => false
  }
}

///|
///|
/// True when a numeric column cell holds no value. Uses the self-comparison
/// trick: NaN is the only double that is not equal to itself, and writing it
/// this way cannot be accidentally rewritten by a constant folder.
pub fn is_missing_number(v : Double) -> Bool {
  v != v
}

///|
/// Numeric value of one field for one document, or None.
pub fn Index::num_of(self : Index, id : String, field : String) -> Double? {
  match self.doc_nums.get(id) {
    Some(num) if !self.deleted.contains(num) =>
      match self.nums.get(num) {
        Some(entries) => {
          let mut found : Double? = None
          for (name, v) in entries {
            if name == field {
              found = Some(v)
              break
            }
          }
          found
        }
        None => None
      }
    _ => None
  }
}

///|
/// Dense numeric column for a field: index i holds the value of internal doc
/// number i, or NaN when the document has no value for the field. Cached until
/// the next mutation. NaN is the sentinel rather than 0.0 because 0.0 is a
/// legitimate value and treating "absent" as zero would corrupt every average.
pub fn Index::num_column(self : Index, field : String) -> Array[Double] {
  match self.num_cols.get(field) {
    Some(col) => col
    None => {
      let col = Array::make(self.doc_ids.length(), nan_sentinel())
      for (num, entries) in self.nums.iter() {
        if num < 0 || num >= col.length() {
          continue
        }
        for (name, value) in entries {
          if name == field {
            col[num] = value
            break
          }
        }
      }
      self.num_cols.set(field, col)
      col
    }
  }
}

///|
/// The "no value" sentinel. A quiet NaN built from the bit pattern rather than
/// 0.0/0.0 (which some constant folders reject) and tested with `v == v`,
/// because NaN is the one value that is not equal to itself.
fn nan_sentinel() -> Double {
  // A quiet NaN from its bit pattern, written literally rather than via
  // `@double.not_a_number` so no deprecated core helper is involved.
  0x7FF8000000000001L.reinterpret_as_double()
}

///|
/// Field names that carry at least one numeric value.
pub fn Index::numeric_fields(self : Index) -> Array[String] {
  let seen : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  let out : Array[String] = []
  for (_, entries) in self.nums.iter() {
    for (name, _) in entries {
      if !seen.contains(name) {
        seen.set(name, ())
        out.push(name)
      }
    }
  }
  out.sort_by(fn(a, b) { a.lexical_compare(b) })
  out
}

///|
/// Run aggregation specs over the documents that a query matched *and* that
/// pass the given facet filters. This is deliberately the same result set the
/// caller returned hits from: aggregating over a different set is the classic
/// way a search UI ends up lying about its own facets.
///
/// `filters` is a list of (field, allowed values) pairs; a document must match
/// at least one value in each pair (OR within, AND across).
pub fn Index::aggregate(
  self : Index,
  query : String,
  specs : Array[AggSpec],
  filters~ : Array[(String, Array[String])] = [],
) -> Array[AggResult] raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval_sorted(parsed)
  let matched : Array[Int32] = []
  for i in 0..<scored.docs.length() {
    let num = scored.docs[i]
    if self.passes_simple_filters(num, filters) {
      matched.push(num)
    }
  }
  let out : Array[AggResult] = []
  for spec in specs {
    out.push(self.run_agg(spec, matched))
  }
  out
}

///|
fn Index::passes_simple_filters(
  self : Index,
  num : Int32,
  filters : Array[(String, Array[String])],
) -> Bool {
  if filters.is_empty() {
    return true
  }
  let doc_facets = self.facets.get_or_default(num, [])
  for (field, allowed) in filters {
    let mut ok = false
    for (name, values) in doc_facets {
      if name == field {
        for v in values {
          if allowed.contains(v) {
            ok = true
            break
          }
        }
      }
      if ok {
        break
      }
    }
    if !ok {
      return false
    }
  }
  true
}

///|
fn Index::run_agg(self : Index, spec : AggSpec, matched : Array[Int32]) -> AggResult {
  match spec {
    TermsAgg(field, size) => {
      let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap([])
      for num in matched {
        for (name, values) in self.facets.get_or_default(num, []) {
          if name == field {
            for v in values {
              counts.set(v, counts.get_or_default(v, 0) + 1)
            }
          }
        }
      }
      let buckets : Array[(String, Int32)] = []
      for (value, count) in counts.iter() {
        buckets.push((value, count))
      }
      buckets.sort_by(fn(a, b) {
        let cmp = b.1.compare(a.1)
        if cmp == 0 {
          a.0.lexical_compare(b.0)
        } else {
          cmp
        }
      })
      let limited : Array[(String, Double)] = []
      let cap = if size <= 0 || size > buckets.length() {
        buckets.length()
      } else {
        size
      }
      for i in 0..<cap {
        limited.push((buckets[i].0, buckets[i].1.to_double()))
      }
      { field, kind: "terms", buckets: limited, stats: None, percentiles: [] }
    }
    StatsAgg(field) => {
      let values = self.collect_numbers(field, matched)
      { field, kind: "stats", buckets: [], stats: Some(summarize(values)), percentiles: [] }
    }
    HistogramAgg(field, interval) => {
      // A non-positive interval would divide by zero and produce one infinite
      // bucket, which is worse than an empty answer.
      if interval <= 0.0 {
        return { field, kind: "histogram", buckets: [], stats: None, percentiles: [] }
      }
      let values = self.collect_numbers(field, matched)
      let counts : @hashmap.HashMap[Int32, Int32] = @hashmap.HashMap([])
      for v in values {
        let bucket = floor_div(v, interval)
        counts.set(bucket, counts.get_or_default(bucket, 0) + 1)
      }
      let keys : Array[Int32] = []
      for (k, _) in counts.iter() {
        keys.push(k)
      }
      keys.sort()
      let buckets : Array[(String, Double)] = []
      for k in keys {
        buckets.push((
          format_bucket(k.to_double() * interval, interval),
          counts.get_or_default(k, 0).to_double(),
        ))
      }
      { field, kind: "histogram", buckets, stats: None, percentiles: [] }
    }
    PercentilesAgg(field, ps) => {
      let values = self.collect_numbers(field, matched)
      values.sort()
      let out : Array[(Double, Double)] = []
      for p in ps {
        out.push((p, percentile_of(values, p)))
      }
      { field, kind: "percentiles", buckets: [], stats: None, percentiles: out }
    }
  }
}

///|
/// Non-NaN values of one field over a document set.
fn Index::collect_numbers(self : Index, field : String, matched : Array[Int32]) -> Array[Double] {
  let col = self.num_column(field)
  let out : Array[Double] = []
  for num in matched {
    if num >= 0 && num < col.length() {
      let v = col[num]
      if v == v {
        out.push(v)
      }
    }
  }
  out
}

///|
fn summarize(values : Array[Double]) -> StatSummary {
  if values.is_empty() {
    return { count: 0, min: 0.0, max: 0.0, avg: 0.0, sum: 0.0 }
  }
  let mut min = values[0]
  let mut max = values[0]
  let mut sum = 0.0
  for v in values {
    if v < min {
      min = v
    }
    if v > max {
      max = v
    }
    sum += v
  }
  {
    count: values.length(),
    min,
    max,
    avg: sum / values.length().to_double(),
    sum,
  }
}

///|
/// Floor division for doubles, correct for negative numerators (a plain
/// `to_int()` truncates toward zero and would put -0.5 and +0.5 in one bucket).
fn floor_div(value : Double, interval : Double) -> Int32 {
  let q = value / interval
  let f = if q >= 0.0 { q.floor() } else { -((-q).ceil()) }
  f.to_int()
}

///|
/// Linear-interpolation percentile over an ascending array (`values` is
/// sorted by the caller). p is 0..100. Linear interpolation rather than
/// nearest-rank because histograms of release counts are tiny integers where
/// nearest-rank jumps between buckets for no reason.
fn percentile_of(values : Array[Double], p : Double) -> Double {
  if values.is_empty() {
    return 0.0
  }
  if values.length() == 1 {
    return values[0]
  }
  let rank = p / 100.0 * (values.length() - 1).to_double()
  let lo = rank.floor().to_int()
  if lo >= values.length() - 1 {
    return values[values.length() - 1]
  }
  let frac = rank - lo.to_double()
  values[lo] * (1.0 - frac) + values[lo + 1] * frac
}

///|
/// Bucket label at three significant-ish digits, so a histogram of integer
/// years reads "2025" and one of prices reads "19.99".
fn format_bucket(value : Double, interval : Double) -> String {
  if interval >= 1.0 && value == value.round() {
    return value.to_int().to_string()
  }
  let scaled = (value * 100.0).round() / 100.0
  scaled.to_string()
}

///|
/// JSON serialization (public API parity with the other result types).
pub fn StatSummary::to_json(self : StatSummary) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["count"] = @json.to_json(self.count)
  fields["min"] = @json.to_json(self.min)
  fields["max"] = @json.to_json(self.max)
  fields["avg"] = @json.to_json(self.avg)
  fields["sum"] = @json.to_json(self.sum)
  Json::object(fields)
}

///|
pub fn AggResult::to_json(self : AggResult) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["field"] = @json.to_json(self.field)
  fields["kind"] = @json.to_json(self.kind)
  let buckets : Array[Json] = []
  for (label, value) in self.buckets {
    buckets.push(Json::array([@json.to_json(label), @json.to_json(value)]))
  }
  fields["buckets"] = Json::array(buckets)
  match self.stats {
    Some(st) => fields["stats"] = st.to_json()
    None => ()
  }
  let ps : Array[Json] = []
  for (p, v) in self.percentiles {
    ps.push(Json::array([@json.to_json(p), @json.to_json(v)]))
  }
  if !ps.is_empty() {
    fields["percentiles"] = Json::array(ps)
  }
  Json::object(fields)
}