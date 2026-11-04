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
    Some(index) =>
      index.highlight(id, field, query) catch {
        _ => ""
      }
    None => ""
  }
}

///|
/// Server-side snippet: densest-highlight window with ellipsis.
#export_name("ms_snippet")
pub fn ms_snippet(id : String, field : String, query : String, max_chars : Int32) -> String {
  match engine.val {
    Some(index) =>
      index.snippet(id, field, query, max_chars~) catch {
        _ => ""
      }
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
