///|
/// Persistence example: save an index, reload it, verify results survive.
/// Run: moon run examples/persistence --target native
async fn main {
  let dir = @fs.tmpdir(prefix="moonseek-example-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/index.msk"
  let index = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  index.add({
    id: "doc1",
    fields: [
      ("title", "搜索引擎原理"),
      ("body", "倒排索引与 BM25 排序"),
    ],
  })
  index.add({
    id: "doc2",
    fields: [("title", "MoonBit"), ("body", "WebAssembly language")],
  })
  // Atomic save: temp file -> fsync -> rename
  try! index.save(path)
  println("saved \{index.doc_count()} documents to \{path}")
  // Reload and verify
  let loaded = try! @moonseek.Index::load(path)
  println(
    "loaded \{loaded.doc_count()} documents, \{loaded.term_count()} terms",
  )
  for hit in (try! loaded.search("搜索引擎")) {
    println("hit: \{hit.id} (score \{hit.score})")
  }
  // Stored fields survive the roundtrip
  match loaded.get_field("doc1", "title") {
    Some(t) => println("stored title: \{t}")
    None => println("no stored title")
  }
  // Portable byte snapshot (works on every backend)
  let image = index.to_bytes()
  let restored = try! @moonseek.Index::from_bytes(image)
  println(
    "byte snapshot: \{image.length()} bytes, \{restored.doc_count()} docs",
  )
}
