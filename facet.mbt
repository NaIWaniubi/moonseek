///|
/// Faceted search: structured keyword fields for filtering and aggregation.
/// Facets are exact-match (not analyzed): each document carries zero or more
/// string values per facet field. Queries can filter by facet values, and
/// search results can include per-facet value counts (aggregations).

///|
/// One facet value with its document count in a result set.
pub(all) struct FacetCount {
  value : String
  count : Int32
} derive(Eq, Debug)

///|
pub extend FacetCount with Eq::{equal, not_equal}

///|
pub extend FacetCount with @debug.Debug::{to_repr}

///|
/// A facet filter: field name + required values (OR within, AND across fields).
pub(all) struct FacetFilter {
  field : String
  values : Array[String]
} derive(Eq, Debug)

///|
pub extend FacetFilter with Eq::{equal, not_equal}

///|
pub extend FacetFilter with @debug.Debug::{to_repr}

///|
/// Search options extending the basic query with facets and pagination.
pub(all) struct SearchOptions {
  limit : Int32
  /// Numeric offset into the sorted result set: skip the first `offset`
  /// hits. NOTE: unlike `Index::search_after`, this is NOT a (score, id)
  /// cursor — pages can shift when documents are added or removed between
  /// calls. Use `search_after` for stable cursor-based pagination.
  offset : Int32
  /// Facet filters: a document must match at least one value per filter.
  filters : Array[FacetFilter]
  /// Facet fields to aggregate counts for in the result set.
  facet_fields : Array[String]
} derive(Eq, Debug)

///|
pub extend SearchOptions with Eq::{equal, not_equal}

///|
pub extend SearchOptions with @debug.Debug::{to_repr}

///|
pub fn SearchOptions::default() -> SearchOptions {
  { limit: 10, offset: 0, filters: [], facet_fields: [], }
}

///|
/// Search result with optional facet aggregations.
pub(all) struct FacetedResult {
  hits : Array[Hit]
  total : Int32
  /// field name -> value counts, sorted by descending count then value.
  facets : Array[(String, Array[FacetCount])]
} derive(Eq, Debug)

///|
pub extend FacetedResult with Eq::{equal, not_equal}

///|
pub extend FacetedResult with @debug.Debug::{to_repr}

///|
/// Set facet values for a document (replaces any previous values).
/// Returns false (and does nothing) when the document does not exist or
/// is deleted; true when the values were stored. Unknown fields are
/// created on the fly (facets don't need schema declaration).
pub fn Index::set_facets(
  self : Index,
  id : String,
  facets : Array[(String, Array[String])],
) -> Bool {
  match self.doc_nums.get(id) {
    Some(num) if !self.deleted.contains(num) => {
      self.facets.set(num, facets)
      true
    }
    _ => false
  }
}

///|
/// Get facet values for a document.
pub fn Index::get_facets(
  self : Index,
  id : String,
) -> Array[(String, Array[String])] {
  match self.doc_nums.get(id) {
    Some(num) if !self.deleted.contains(num) =>
      self.facets.get_or_default(num, [])
    _ => []
  }
}

///|
/// Check if a document passes all facet filters.
fn Index::passes_filters(
  self : Index,
  doc : Int32,
  filters : Array[FacetFilter],
) -> Bool {
  if filters.is_empty() {
    return true
  }
  let doc_facets = self.facets.get_or_default(doc, [])
  for filter in filters {
    let mut matched = false
    for (name, values) in doc_facets {
      if name == filter.field {
        for v in filter.values {
          if values.contains(v) {
            matched = true
            break
          }
        }
      }
      if matched {
        break
      }
    }
    if !matched {
      return false
    }
  }
  true
}

///|
/// Faceted search: query + filters + aggregations + pagination.
pub fn Index::search_faceted(
  self : Index,
  query : String,
  options~ : SearchOptions = SearchOptions::default(),
) -> FacetedResult raise QueryError {
  let parsed = parse_query(
    query,
    analyzer=self.analyzer,
    fields=self.field_names(),
  )
  let scored = self.eval(parsed)
  // Apply facet filters and collect all matching hits.
  let all_hits : Array[Hit] = []
  let matching_docs : Array[Int32] = []
  for (doc, score) in scored.iter() {
    if self.passes_filters(doc, options.filters) {
      all_hits.push({ id: self.doc_ids[doc], score, })
      matching_docs.push(doc)
    }
  }
  all_hits.sort_by(fn(a, b) {
    let cmp = b.score.compare(a.score)
    if cmp == 0 {
      a.id.lexical_compare(b.id)
    } else {
      cmp
    }
  })
  let total = all_hits.length()
  // Pagination
  let start = if options.offset < 0 { 0 } else { options.offset }
  let end = if options.limit <= 0 {
    total
  } else {
    let e = start + options.limit
    if e > total {
      total
    } else {
      e
    }
  }
  let hits : Array[Hit] = []
  if start < total {
    for i in start..<end {
      hits.push(all_hits[i])
    }
  }
  // Facet aggregations over the filtered result set
  let facets : Array[(String, Array[FacetCount])] = []
  for field in options.facet_fields {
    let counts : @hashmap.HashMap[String, Int32] = @hashmap.HashMap([])
    for doc in matching_docs {
      let doc_facets = self.facets.get_or_default(doc, [])
      for (name, values) in doc_facets {
        if name == field {
          for v in values {
            counts.set(v, counts.get_or_default(v, 0) + 1)
          }
        }
      }
    }
    let sorted : Array[FacetCount] = []
    for (value, count) in counts.iter() {
      sorted.push({ value, count, })
    }
    sorted.sort_by(fn(a, b) {
      let cmp = b.count.compare(a.count)
      if cmp == 0 {
        a.value.compare(b.value)
      } else {
        cmp
      }
    })
    facets.push((field, sorted))
  }
  { hits, total, facets, }
}

///|
/// JSON serialization for result types (public API parity with web/api.mbt).
pub fn Hit::to_json(self : Hit) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["id"] = @json.to_json(self.id)
  fields["score"] = @json.to_json(self.score)
  Json::object(fields)
}

///|
pub fn ScoreDetail::to_json(self : ScoreDetail) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["field"] = @json.to_json(self.field)
  fields["term"] = @json.to_json(self.term)
  fields["tf"] = @json.to_json(self.tf)
  fields["df"] = @json.to_json(self.df)
  fields["idf"] = @json.to_json(self.idf)
  fields["norm"] = @json.to_json(self.norm)
  fields["score"] = @json.to_json(self.score)
  Json::object(fields)
}

///|
pub fn Explanation::to_json(self : Explanation) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["id"] = @json.to_json(self.id)
  fields["total_score"] = @json.to_json(self.total_score)
  fields["details"] = Json::array(self.details.map(fn(d) { d.to_json() }))
  Json::object(fields)
}

///|
pub fn FacetCount::to_json(self : FacetCount) -> Json {
  Json::array([@json.to_json(self.value), @json.to_json(self.count)])
}

///|
pub fn SearchOptions::to_json(self : SearchOptions) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["limit"] = @json.to_json(self.limit)
  fields["offset"] = @json.to_json(self.offset)
  Json::object(fields)
}

///|
pub fn FacetFilter::to_json(self : FacetFilter) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["field"] = @json.to_json(self.field)
  fields["values"] = Json::array(self.values.map(fn(v) { @json.to_json(v) }))
  Json::object(fields)
}

///|
pub fn FacetedResult::to_json(self : FacetedResult) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["hits"] = Json::array(self.hits.map(fn(h) { h.to_json() }))
  fields["total"] = @json.to_json(self.total)
  let facet_obj : Map[String, Json] = Map([])
  for (name, counts) in self.facets {
    facet_obj[name] = Json::array(counts.map(fn(c) { c.to_json() }))
  }
  fields["facets"] = Json::object(facet_obj)
  Json::object(fields)
}

///|
pub impl Default for SearchOptions with fn default() -> SearchOptions {
  { limit: 10, offset: 0, filters: [], facet_fields: [], }
}
