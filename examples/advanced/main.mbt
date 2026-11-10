///|
/// Advanced example: every 0.3.0 capability in one run.
/// Faceted search (filter + aggregation + offset pagination), fuzzy search
/// (BK-tree), did-you-mean suggestions, score explanation, sort orders,
/// cursor pagination, and server-side highlighting / snippets.
/// Run: moon run examples/advanced --target native
fn main {
  let index = @moonseek.Index::new([
    { name: "title", weight: 3.0, },
    { name: "body", weight: 1.0, },
  ])
  // 6 bilingual documents; facets are exact-match keyword bags (not analyzed).
  let docs : Array[@moonseek.Document] = [
    {
      id: "doc-1",
      fields: [
        ("title", "MoonBit 语言教程"),
        (
          "body", "MoonBit 是一门面向 WebAssembly 的编程语言，编译器速度快，类型系统安全。",
        ),
      ],
    },
    {
      id: "doc-2",
      fields: [
        ("title", "Full-Text Search Engines"),
        (
          "body", "A search engine builds an inverted index and ranks documents with BM25 scoring.",
        ),
      ],
    },
    {
      id: "doc-3",
      fields: [
        ("title", "倒排索引原理"),
        (
          "body", "倒排索引把词项映射到文档列表，是搜索引擎与数据库全文检索的核心数据结构。",
        ),
      ],
    },
    {
      id: "doc-4",
      fields: [
        ("title", "Rust Memory Safety"),
        (
          "body", "Rust guarantees memory safety without a garbage collector using ownership and borrow checking.",
        ),
      ],
    },
    {
      id: "doc-5",
      fields: [
        ("title", "WebAssembly Runtime"),
        (
          "body", "WebAssembly is a portable binary format; a wasm runtime executes it inside the browser sandbox.",
        ),
      ],
    },
    {
      id: "doc-6",
      fields: [
        ("title", "搜索引擎分词"),
        (
          "body", "中文分词使用重叠二元语法，无需词典即可建立全文索引，短语查询依然有效。",
        ),
      ],
    },
  ]
  for doc in docs {
    index.add(doc)
  }
  // Facets: language (zh/en), topic (free-form keyword bag).
  let _ = index.set_facets("doc-1", [
    ("lang", ["zh"]),
    ("topic", ["moonbit", "language"]),
  ])
  let _ = index.set_facets("doc-2", [
    ("lang", ["en"]),
    ("topic", ["search", "index"]),
  ])
  let _ = index.set_facets("doc-3", [
    ("lang", ["zh"]),
    ("topic", ["search", "index"]),
  ])
  let _ = index.set_facets("doc-4", [
    ("lang", ["en"]),
    ("topic", ["language", "safety"]),
  ])
  let _ = index.set_facets("doc-5", [
    ("lang", ["en"]),
    ("topic", ["wasm", "runtime"]),
  ])
  let _ = index.set_facets("doc-6", [
    ("lang", ["zh"]),
    ("topic", ["search", "wasm"]),
  ])
  println("=== faceted search: query + filter + aggregation ===")
  let opts : @moonseek.SearchOptions = {
    limit: 5,
    offset: 0,
    filters: [{ field: "lang", values: ["zh"], }],
    facet_fields: ["topic", "lang"],
  }
  let result = try! index.search_faceted("搜索引擎", options=opts)
  println(
    "query \"搜索引擎\" lang:zh -> \{result.total} matches, \{result.hits.length()} shown",
  )
  for hit in result.hits {
    println("  hit: \{hit.id} (score \{hit.score})")
  }
  for (field, counts) in result.facets {
    let parts : Array[String] = []
    for c in counts {
      parts.push("\{c.value}:\{c.count}")
    }
    println("  facet \{field}: \{parts.join(", ")}")
  }
  println("=== faceted pagination: offset page 2 ===")
  let page2 = try! index.search_faceted(
    "search OR 搜索 OR engine OR 引擎",
    options={ limit: 2, offset: 2, filters: [], facet_fields: [], },
  )
  println(
    "offset=2 limit=2 -> \{page2.total} total, hits: \{page2.hits.length()}",
  )
  for hit in page2.hits {
    println("  hit: \{hit.id} (score \{hit.score})")
  }
  println("=== fuzzy search: BK-tree assisted (serch -> search) ===")
  let tree = index.bk_tree()
  println("bk-tree over \{tree.len()} terms")
  let variants = index.fuzzy_terms_fast("serch", max_distance=2)
  for m in variants {
    println("  variant: \{m.term} (distance \{m.distance})")
  }
  for hit in (try! index.fuzzy_search("serch", max_distance=2)) {
    println("  fuzzy hit: \{hit.id} (score \{hit.score})")
  }
  println("=== did-you-mean: suggest for a misspelled query ===")
  match index.suggest("serch engin") {
    Some(fixed) => println("did you mean: \"\{fixed}\"?")
    None => println("nothing to suggest")
  }
  println("=== explain: BM25 breakdown for one hit ===")
  match (try! index.explain("倒排索引", "doc-3")) {
    Some(exp) => {
      println(
        "doc \{exp.id} total score \{exp.total_score}, \{exp.details.length()} terms:",
      )
      for d in exp.details {
        println(
          "  \{d.field}:\{d.term}  tf=\{d.tf} df=\{d.df} idf=\{d.idf} norm=\{d.norm} score=\{d.score}",
        )
      }
    }
    None => println("document does not match")
  }
  println("=== sort orders: score desc vs id asc ===")
  for
    hit in (try! index.search_sorted(
      "search OR 搜索 OR index OR 索引",
      limit=3,
      sort=@moonseek.SortOrder::ScoreDesc,
    )) {
    println("  score desc: \{hit.id} (\{hit.score})")
  }
  for
    hit in (try! index.search_sorted(
      "search OR 搜索 OR index OR 索引",
      limit=3,
      sort=@moonseek.SortOrder::IdAsc,
    )) {
    println("  id asc:     \{hit.id} (\{hit.score})")
  }
  println("=== cursor pagination: search_after page 2 ===")
  let page1 = try! index.search("search OR 搜索 OR engine OR 引擎", limit=2)
  for hit in page1 {
    println("  page 1: \{hit.id} (\{hit.score})")
  }
  let last = page1[page1.length() - 1]
  let page2b = try! index.search_after(
    "search OR 搜索 OR engine OR 引擎",
    after_score=last.score,
    after_id=last.id,
    limit=2,
  )
  for hit in page2b {
    println("  page 2: \{hit.id} (\{hit.score})")
  }
  println("=== highlighting & snippet ===")
  let marked = try! index.highlight("doc-3", "body", "倒排索引")
  println("  highlight: \{marked}")
  let snip = try! index.snippet("doc-3", "body", "搜索引擎", max_chars=24)
  println("  snippet:   \{snip}")
}
