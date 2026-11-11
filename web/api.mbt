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
/// The one error protocol for every JSON-returning entry point: failures
/// come back as {"error":"..."} so callers can distinguish failure from
/// an empty result.
fn error_json(msg : String) -> String {
  let fields : Map[String, Json] = Map([])
  fields["error"] = @json.to_json(msg)
  Json::object(fields).stringify()
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
    // CodecError implements Show, so users get a readable message
    // instead of a Debug repr like CodecError::BadMagic(...).
    e => e.to_string()
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
        e => return error_json(e.to_string())
      }
      Json::array(hits.map(fn(h) { h.to_json() })).stringify()
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
    Some(index) =>
      index.highlight(id, field, query) catch {
        e => error_json(e.to_string())
      }
    None => error_json("index not initialized")
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
    Some(index) =>
      index.snippet(id, field, query, max_chars~) catch {
        e => error_json(e.to_string())
      }
    None => error_json("index not initialized")
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
        e => return error_json(e.to_string())
      }
      Json::array(hits.map(fn(h) { h.to_json() })).stringify()
    }
    None => error_json("index not initialized")
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
      if index.set_facets(id, facets) {
        ""
      } else {
        "no such document: " + id
      }
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
  ms_search_faceted_fields(query, filters_json, limit, offset, "cat lang")
}

///|
/// Faceted search with caller-chosen facet fields (space-separated names).
/// The demo indexes a package registry, whose facets are license/deps/year,
/// not the toy corpus's cat/lang — hardcoding the field names made facet
/// aggregation silently return nothing.
#export_name("ms_search_faceted_fields")
pub fn ms_search_faceted_fields(
  query : String,
  filters_json : String,
  limit : Int32,
  offset : Int32,
  facet_fields : String,
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
      let fields : Array[String] = []
      for name in facet_fields.split(" ") {
        if !name.is_empty() {
          fields.push(name.to_owned())
        }
      }
      let options : @moonseek.SearchOptions = {
        limit,
        offset,
        filters,
        facet_fields: fields,
      }
      let result = index.search_faceted(query, options~) catch {
        e => return error_json(e.to_string())
      }
      let hits : Array[Json] = []
      for hit in result.hits {
        let fields : Map[String, Json] = hit
          .to_json()
          .as_object()
          .unwrap_or(Map([]))
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
      let exp = index.explain(query, id) catch {
        e => return error_json(e.to_string())
      }
      match exp {
        None => "null"
        Some(e) => e.to_json().stringify()
      }
    }
    None => error_json("index not initialized")
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

///|
/// Snapshot the current index as a base64 string.
///
/// `Bytes` has no stable JS ABI (a `Bytes` argument or return value fails to
/// cross the boundary), so the browser transport is base64 text. This is also
/// what lets a snapshot written by the *native* build load into the *wasm*
/// build: the MSK3 byte format is the same, only the wrapper differs.
#export_name("ms_save_b64")
pub fn ms_save_b64() -> String {
  match engine.val {
    Some(index) => @base64.encode(index.to_bytes())
    None => ""
  }
}

///|
/// Load an index from a base64 snapshot. Returns "" on success, or an error
/// message (bad base64, bad magic, checksum mismatch, truncation).
#export_name("ms_load_b64")
pub fn ms_load_b64(text : String) -> String {
  let bytes = @base64.decode(text) catch {
    e => return "bad base64: " + @debug.to_string(e)
  }
  try {
    let index = @moonseek.Index::from_bytes(bytes)
    engine.val = Some(index)
    ""
  } catch {
    e => e.to_string()
  }
}

///|
/// Export the index as a JSON array of the stored documents, so a browser
/// session can be handed to another tool without re-typing anything.
/// Each entry is {id, title, body}; only live documents appear.
#export_name("ms_dump")
pub fn ms_dump() -> String {
  match engine.val {
    Some(index) => {
      let items : Array[Json] = []
      for num in 0..<index.slot_count() {
        if index.is_deleted(num) {
          continue
        }
        let id = match index.doc_id(num) {
          Some(id) => id
          None => continue
        }
        let obj : Map[String, Json] = Map([])
        obj["id"] = @json.to_json(id)
        obj["title"] = @json.to_json(index.get_field(id, "title").unwrap_or(""))
        obj["body"] = @json.to_json(index.get_field(id, "body").unwrap_or(""))
        items.push(Json::object(obj))
      }
      Json::array(items).stringify()
    }
    None => "[]"
  }
}

///|
/// Count of live documents carrying a value in `field` — used by the demo to
/// size its progress bars without re-parsing the whole dump.
#export_name("ms_live_count")
pub fn ms_live_count() -> Int32 {
  match engine.val {
    Some(index) => index.doc_count()
    None => 0
  }
}

///|
/// Set the field schema. Must be called before any document is added; the
/// demo uses it to switch from the toy title/body schema to the package
/// registry's four-field schema. Returns "" on success.
#export_name("ms_set_schema")
pub fn ms_set_schema(spec : String) -> String {
  // spec is "name:weight name:weight ..." — a compact, unambiguous wire form
  // that avoids JSON parsing on the hot path of a page load.
  let schema : Array[@moonseek.FieldSchema] = []
  for part in spec.split(" ") {
    if part.is_empty() {
      continue
    }
    match part.find(":") {
      Some(i) => {
        let name = part[:i].to_owned()
        let weight = @string.parse_double(part[i + 1:].to_owned()) catch {
          _ => return "bad weight in schema spec: " + part.to_owned()
        }
        schema.push({ name, weight })
      }
      None => return "bad schema entry (expected name:weight): " + part.to_owned()
    }
  }
  if schema.is_empty() {
    return "empty schema"
  }
  engine.val = Some(@moonseek.Index::new(schema))
  ""
}

///|
/// Add a document with an arbitrary set of fields.
/// `fields_json` is [["title","..."],["keywords","..."]].
#export_name("ms_add_doc")
pub fn ms_add_doc(id : String, fields_json : String) -> String {
  match engine.val {
    Some(index) => {
      let parsed = @json.parse(fields_json) catch {
        e => return "bad field json: " + @debug.to_string(e)
      }
      let fields : Array[(String, String)] = []
      match parsed.as_array() {
        Some(items) =>
          for item in items {
            if item.as_array() is Some(pair) && pair.length() == 2 {
              match (pair[0].as_string(), pair[1].as_string()) {
                (Some(name), Some(value)) => fields.push((name, value))
                _ => ()
              }
            }
          }
        None => return "fields_json is not an array"
      }
      index.add({ id, fields })
      ""
    }
    None => "index not initialized"
  }
}
