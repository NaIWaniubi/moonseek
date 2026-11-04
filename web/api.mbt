///|
/// Browser-facing API. All functions cross the JS boundary with stable
/// ABI types only (String, Int, Double, Bytes). The index lives in a
/// module-level cell; the demo is single-threaded by construction.

///|
let engine : @ref.Ref[@moonseek.Index?] = @ref.Ref(None)

///|
fn schema() -> Array[@moonseek.FieldSchema] {
  [{ name: "title", weight: 3.0, }, { name: "body", weight: 1.0, }]
}

///|
/// Create a fresh empty index, discarding any previous one.
#export_name("ms_init")
pub fn ms_init() -> Unit {
  engine.val = Some(@moonseek.Index::new(schema()))
}

///|
/// Load an index from a snapshot byte image (Uint8Array in JS).
/// Returns "" on success, or an error message.
#export_name("ms_load")
pub fn ms_load(image : Bytes) -> String {
  try {
    let index = @moonseek.Index::from_bytes(image)
    engine.val = Some(index)
    ""
  } catch {
    e => @debug.to_string(e)
  }
}

///|
/// Export the current index as a snapshot byte image.
#export_name("ms_save")
pub fn ms_save() -> Bytes {
  match engine.val {
    Some(index) => index.to_bytes()
    None => b""
  }
}

///|
/// Add a document. Returns "" on success, or an error message.
#export_name("ms_add")
pub fn ms_add(id : String, title : String, body : String) -> String {
  match engine.val {
    Some(index) => {
      index.add({ id, fields: [("title", title), ("body", body)], })
      ""
    }
    None => "index not initialized"
  }
}

///|
/// Search the index. Returns a JSON array of {id, score} objects.
#export_name("ms_search")
pub fn ms_search(query : String, limit : Int32) -> String {
  match engine.val {
    Some(index) => {
      let hits = index.search(query, limit~) catch {
        e => return "{\"error\":\"\{@debug.to_string(e)}\"}"
      }
      let items : Array[Json] = []
      for hit in hits {
        let fields : Map[String, Json] = Map([])
        fields["id"] = @json.to_json(hit.id)
        fields["score"] = @json.to_json(hit.score)
        items.push(Json::object(fields))
      }
      Json::array(items).stringify()
    }
    None => "{\"error\":\"index not initialized\"}"
  }
}

///|
/// Number of documents in the index.
#export_name("ms_count")
pub fn ms_count() -> Int32 {
  match engine.val {
    Some(index) => index.doc_count()
    None => 0
  }
}

///|
/// Number of distinct terms in the index.
#export_name("ms_terms")
pub fn ms_terms() -> Int32 {
  match engine.val {
    Some(index) => index.term_count()
    None => 0
  }
}

///|
/// Retrieve a stored field's original text ("" if absent).
#export_name("ms_get")
pub fn ms_get(id : String, field : String) -> String {
  match engine.val {
    Some(index) => index.get_field(id, field).unwrap_or("")
    None => ""
  }
}

///|
/// Delete a document by id. Returns 1 if deleted, 0 if not found.
#export_name("ms_delete")
pub fn ms_delete(id : String) -> Int32 {
  match engine.val {
    Some(index) => if index.delete(id) { 1 } else { 0 }
    None => 0
  }
}

///|
/// Snapshot size in bytes (Bytes has no stable JS ABI, so expose the
/// length as an Int for the demo's stats line).
#export_name("ms_snapshot_size")
pub fn ms_snapshot_size() -> Int32 {
  match engine.val {
    Some(index) => index.to_bytes().length()
    None => 0
  }
}

///|
/// Server-side highlight: returns the field text with <mark> tags and
/// HTML escaping applied by the engine (not by JS).
#export_name("ms_highlight")
pub fn ms_highlight(id : String, field : String, query : String) -> String {
  match engine.val {
    Some(index) => index.highlight(id, field, query) catch { _ => "" }
    None => ""
  }
}

///|
/// Server-side snippet: densest-highlight window with ellipsis.
#export_name("ms_snippet")
pub fn ms_snippet(
  id : String,
  field : String,
  query : String,
  max_chars : Int32,
) -> String {
  match engine.val {
    Some(index) => index.snippet(id, field, query, max_chars~) catch { _ => "" }
    None => ""
  }
}

///|
/// Did-you-mean: returns a corrected query string, or "" if none.
#export_name("ms_suggest")
pub fn ms_suggest(query : String) -> String {
  match engine.val {
    Some(index) => index.suggest(query).unwrap_or("")
    None => ""
  }
}

///|
/// Fuzzy search: returns a JSON array of {id, score} for typo-tolerant matches.
#export_name("ms_fuzzy")
pub fn ms_fuzzy(term : String, max_distance : Int32, limit : Int32) -> String {
  match engine.val {
    Some(index) => {
      let hits = index.fuzzy_search(term, max_distance~, limit~) catch {
        _ => return "[]"
      }
      let items : Array[Json] = []
      for hit in hits {
        let fields : Map[String, Json] = Map([])
        fields["id"] = @json.to_json(hit.id)
        fields["score"] = @json.to_json(hit.score)
        items.push(Json::object(fields))
      }
      Json::array(items).stringify()
    }
    None => "[]"
  }
}

///|
/// Set facet values for a document: `json` is [["lang",["en"]],["topic",["db"]]].
/// Returns "" on success or an error message.
#export_name("ms_set_facets")
pub fn ms_set_facets(id : String, json : String) -> String {
  match engine.val {
    Some(index) => {
      let parsed = @json.parse(json) catch {
        e => return "bad facet json: " + @debug.to_string(e)
      }
      let facets : Array[(String, Array[String])] = []
      match parsed.as_array() {
        Some(items) =>
          for item in items {
            match item.as_array() {
              Some(pair) if pair.length() == 2 =>
                match (pair[0].as_string(), pair[1].as_array()) {
                  (Some(name), Some(values)) => {
                    let vals : Array[String] = []
                    for v in values {
                      match v.as_string() {
                        Some(s) => vals.push(s)
                        None => ()
                      }
                    }
                    facets.push((name, vals))
                  }
                  _ => ()
                }
              _ => ()
            }
          }
        None => ()
      }
      index.set_facets(id, facets)
      ""
    }
    None => "index not initialized"
  }
}

///|
/// Faceted search with the demo's fixed facet fields (lang, topic).
/// `filters_json` is [["lang","zh"],["topic","db"]] or "" for no filter.
/// Returns {hits:[{id,score,title,snippet}], total, facets:{lang:[[v,n]]}}.
#export_name("ms_search_faceted")
pub fn ms_search_faceted(
  query : String,
  filters_json : String,
  limit : Int32,
  offset : Int32,
) -> String {
  match engine.val {
    Some(index) => {
      let filters : Array[@moonseek.FacetFilter] = []
      if filters_json != "" {
        let parsed = @json.parse(filters_json) catch {
          _ => return "{\"error\":\"bad filters json\"}"
        }
        match parsed.as_array() {
          Some(items) =>
            for item in items {
              match item.as_array() {
                Some(pair) if pair.length() == 2 =>
                  match (pair[0].as_string(), pair[1].as_string()) {
                    (Some(field), Some(value)) =>
                      filters.push({ field, values: [value], })
                    _ => ()
                  }
                _ => ()
              }
            }
          None => ()
        }
      }
      let options : @moonseek.SearchOptions = {
        limit,
        offset,
        filters,
        facet_fields: ["cat", "lang"],
      }
      let result = index.search_faceted(query, options~) catch {
        e => return "{\"error\":\"" + @debug.to_string(e) + "\"}"
      }
      let hits : Array[Json] = []
      for hit in result.hits {
        let fields : Map[String, Json] = Map([])
        fields["id"] = @json.to_json(hit.id)
        fields["score"] = @json.to_json(hit.score)
        fields["title"] = @json.to_json(
          index.get_field(hit.id, "title").unwrap_or(""),
        )
        fields["snippet"] = @json.to_json(
          index.snippet(hit.id, "body", query, max_chars=160) catch {
            _ => ""
          },
        )
        hits.push(Json::object(fields))
      }
      let facet_obj : Map[String, Json] = Map([])
      for (field, counts) in result.facets {
        let arr : Array[Json] = []
        for c in counts {
          arr.push(
            Json::array([@json.to_json(c.value), @json.to_json(c.count)]),
          )
        }
        facet_obj[field] = Json::array(arr)
      }
      let out : Map[String, Json] = Map([])
      out["hits"] = Json::array(hits)
      out["total"] = @json.to_json(result.total)
      out["facets"] = Json::object(facet_obj)
      Json::object(out).stringify()
    }
    None => "{\"error\":\"index not initialized\"}"
  }
}

///|
/// Explain a hit's score: JSON {id, total, details:[{field,term,tf,df,idf,score}]}.
#export_name("ms_explain")
pub fn ms_explain(id : String, query : String) -> String {
  match engine.val {
    Some(index) => {
      let exp = index.explain(query, id) catch { _ => None }
      match exp {
        None => "null"
        Some(e) => {
          let details : Array[Json] = []
          for d in e.details {
            let fields : Map[String, Json] = Map([])
            fields["field"] = @json.to_json(d.field)
            fields["term"] = @json.to_json(d.term)
            fields["tf"] = @json.to_json(d.tf)
            fields["df"] = @json.to_json(d.df)
            fields["idf"] = @json.to_json(d.idf)
            fields["score"] = @json.to_json(d.score)
            details.push(Json::object(fields))
          }
          let out : Map[String, Json] = Map([])
          out["id"] = @json.to_json(e.id)
          out["total"] = @json.to_json(e.total_score)
          out["details"] = Json::array(details)
          Json::object(out).stringify()
        }
      }
    }
    None => "null"
  }
}

///|
/// List all terms in a field as a JSON array of [term, doc_freq] pairs,
/// sorted by descending doc frequency (for the index inspector).
#export_name("ms_term_stats")
pub fn ms_term_stats(field : String, limit : Int32) -> String {
  match engine.val {
    Some(index) => {
      let terms = index.terms_of(field)
      let stats : Array[(String, Int32)] = []
      for term in terms {
        stats.push((term, index.doc_freq(field, term)))
      }
      stats.sort_by(fn(a, b) { b.1.compare(a.1) })
      let items : Array[Json] = []
      let mut count = 0
      for (term, freq) in stats {
        if limit > 0 && count >= limit {
          break
        }
        items.push(Json::array([@json.to_json(term), @json.to_json(freq)]))
        count += 1
      }
      Json::array(items).stringify()
    }
    None => "[]"
  }
}
