///|
/// Shared loader: mooncakes registry JSON -> a moonseek index.
///
/// The registry dump is deliberately indexed as four fields, because that is
/// what a package search actually needs: the package name (strongest signal),
/// the author's own keyword list, the prose description, and the dependency
/// edges (so "who depends on moonbitlang/async" is answerable).

///|
/// The field schema every registry consumer uses. Weights are relative: a
/// name hit outranks a keyword hit, which outranks prose and dependency text.
pub fn registry_schema() -> Array[@moonseek.FieldSchema] {
  [
    { name: "title", weight: 6.0 },
    { name: "keywords", weight: 3.0 },
    { name: "desc", weight: 1.0 },
    { name: "deps", weight: 1.5 },
  ]
}

///|
/// Build an index from the `docs` array of a registry dump.
/// Returns the index plus the number of packages that were skipped because
/// they had no `id` (a data-integrity counter, not an error).
pub fn build_registry_index(
  docs : Array[Json],
  schema~ : Array[@moonseek.FieldSchema] = registry_schema(),
  bm25~ : @moonseek.Bm25Params = @moonseek.Bm25Params::default(),
) -> (@moonseek.Index, Int32) {
  let index = @moonseek.Index::new(schema, bm25~)
  // Only feed fields the schema declares: an ablation that drops a field must
  // build a genuinely smaller index, not one whose extra fields abort `add`.
  let declared : @hashmap.HashMap[String, Unit] = @hashmap.HashMap([])
  for f in schema {
    declared.set(f.name, ())
  }
  let mut skipped = 0
  for item in docs {
    let id = str_of(item, "id")
    if id == "" {
      skipped += 1
      continue
    }
    let all_fields : Array[(String, String)] = [
      ("title", str_of(item, "title")),
      ("keywords", strings_of(item, "keywords").join(" ")),
      ("desc", str_of(item, "desc")),
      ("deps", strings_of(item, "deps").join(" ")),
    ]
    let fields : Array[(String, String)] = []
    for pair in all_fields {
      if declared.contains(pair.0) {
        fields.push(pair)
      }
    }
    index.add({ id, fields })
    if item is Object(obj) {
      if obj.get("facets") is Some(Array(rows)) {
        let _ = index.set_facets(id, parse_facets(rows))
      }
    }
  }
  (index, skipped)
}

///|
fn parse_facets(rows : Array[Json]) -> Array[(String, Array[String])] {
  let facets : Array[(String, Array[String])] = []
  for row in rows {
    if row is Array([String(name), Array(values), ..]) {
      let vals : Array[String] = []
      for v in values {
        if v is String(s) {
          vals.push(s)
        }
      }
      facets.push((name, vals))
    }
  }
  facets
}

///|
pub fn str_of(obj : Json, key : String) -> String {
  guard obj is Object(fields) else { return "" }
  guard fields.get(key) is Some(String(s)) else { return "" }
  s
}

///|
pub fn strings_of(obj : Json, key : String) -> Array[String] {
  let out : Array[String] = []
  guard obj is Object(fields) else { return out }
  guard fields.get(key) is Some(Array(items)) else { return out }
  for item in items {
    if item is String(s) {
      out.push(s)
    }
  }
  out
}

///|
/// Read a numeric field as a Double (0.0 when absent).
pub fn num_of(obj : Json, key : String) -> Double {
  guard obj is Object(fields) else { return 0.0 }
  guard fields.get(key) is Some(Number(n, ..)) else { return 0.0 }
  n
}
