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
        let fields : Map[String, Json] = Map::new()
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
