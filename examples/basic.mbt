///|
/// Basic usage: build an index, run queries, inspect results.
/// Run: moon run examples --target native
fn main {
  let index = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  index.add({
    id: "moonbit",
    fields: [
      ("title", "MoonBit Programming Language"),
      ("body", "MoonBit is a fast language for WebAssembly and native targets."),
    ],
  })
  index.add({
    id: "search-zh",
    fields: [
      ("title", "全文搜索引擎"),
      (
        "body", "倒排索引是搜索引擎的核心，BM25 负责相关性排序。",
      ),
    ],
  })
  index.add({
    id: "rust",
    fields: [
      ("title", "Rust Memory Safety"),
      ("body", "Rust guarantees memory safety without a garbage collector."),
    ],
  })
  println("=== term query: moonbit ===")
  for hit in (try! index.search("moonbit")) {
    println("\{hit.id}: \{hit.score}")
  }
  println("=== chinese query: 搜索引擎 ===")
  for hit in (try! index.search("搜索引擎")) {
    println("\{hit.id}: \{hit.score}")
  }
  println("=== boolean: language NOT rust ===")
  for hit in (try! index.search("language NOT rust")) {
    println("\{hit.id}: \{hit.score}")
  }
  println("=== phrase: \"memory safety\" ===")
  for hit in (try! index.search("\"memory safety\"")) {
    println("\{hit.id}: \{hit.score}")
  }
  println("=== field scoped: title:rust ===")
  for hit in (try! index.search("title:rust")) {
    println("\{hit.id}: \{hit.score}")
  }
  println("=== stored document ===")
  match index.get_document("search-zh") {
    Some(doc) =>
      for (name, text) in doc.fields {
        println("\{name}: \{text}")
      }
    None => println("not found")
  }
}
