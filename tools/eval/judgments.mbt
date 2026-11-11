///|
/// Query judgments for the mooncakes registry corpus.
///
/// This file is the honest part of the benchmark and needs to be read as
/// such: the relevance labels are DERIVED, not human-assessed. Each query
/// carries its evidence in the source data itself —
///
///   1. `Keywords`  — the query is one of the author's own keyword strings,
///                    so every package declaring it is a relevance-2 answer.
///   2. `DependsOn` — the query is a package name, and relevance is judged
///                    from the dependency edges other authors declared.
///   3. `NamePart`  — the query is a word of a package's own name.
///
/// Derived labels measure one thing very precisely: whether the engine
/// retrieves what the corpus *structurally* says is relevant. They are not
/// a substitute for a human-judged BEIR-style set, and the report says so.
/// Because the label definition is fixed in advance and independent of the
/// retriever, the numbers are still comparable across configurations — which
/// is exactly what the ablation study needs.

///|
/// How a query's relevance labels are derived from the corpus.
pub(all) enum Judgement {
  /// Query equals a keyword; packages declaring that keyword are relevant.
  Keywords(String)
  /// Query is a package name; relevance comes from declared dependency edges.
  DependsOn(String)
  /// Query is a word from a package name.
  NamePart(String)
} derive(Eq, Debug)

///|
/// One benchmark query with its label derivation rule.
pub(all) struct EvalQuery {
  /// The query string sent to the engine, verbatim.
  text : String
  judgement : Judgement
  /// Human-readable note explaining why this query is interesting.
  note : String
}

///|
/// The curated query set. Every entry is a real question a MoonBit user
/// would ask of this registry, and every entry's labels are computable from
/// the corpus alone.
pub fn eval_queries() -> Array[EvalQuery] {
  [
    // --- keyword queries: crowded topics, the hard ones for ranking ---
    { text: "parser", judgement: Keywords("parser"), note: "232 packages declare it" },
    { text: "wasm", judgement: Keywords("wasm"), note: "240 packages, name collision with title" },
    { text: "json", judgement: Keywords("json"), note: "150 packages, several named *json*" },
    { text: "cli", judgement: Keywords("cli"), note: "173 packages, name and keyword both hit" },
    { text: "http", judgement: Keywords("http"), note: "95 packages" },
    { text: "async", judgement: Keywords("async"), note: "47 packages, it is also a dependency hub" },
    { text: "gui", judgement: Keywords("gui"), note: "sparse topic" },
    { text: "database", judgement: Keywords("database"), note: "no package is *named* database" },
    { text: "regexp", judgement: Keywords("regexp"), note: "small, precise topic" },
    { text: "serialization", judgement: Keywords("serialization"), note: "long keyword, one token" },
    { text: "compiler", judgement: Keywords("compiler"), note: "no title hits at all" },
    { text: "benchmark", judgement: Keywords("benchmark"), note: "sparse topic" },
    // --- dependency queries: the graph question ---
    { text: "moonbitlang/async", judgement: DependsOn("moonbitlang/async"), note: "938 dependents" },
    { text: "moonbitlang/x", judgement: DependsOn("moonbitlang/x"), note: "898 dependents" },
    { text: "cli/core", judgement: DependsOn("cli/core"), note: "76 dependents" },
    // --- name-part queries ---
    { text: "moon", judgement: NamePart("moon"), note: "348 packages named *moon*" },
    { text: "mbt", judgement: NamePart("mbt"), note: "54 packages named *mbt*" },
  ]
}

///|
/// Relevance grades for one query: package id -> grade (0..2).
/// Keys with no grade are implicitly 0.
pub fn build_qrels(
  index : @moonseek.Index,
  docs : Array[Json],
  query : EvalQuery,
) -> @hashmap.HashMap[String, Int32] {
  let qrels : @hashmap.HashMap[String, Int32] = @hashmap.HashMap([])
  match query.judgement {
    Keywords(kw) =>
      for doc in docs {
        let id = @reglib.str_of(doc, "id")
        if id == "" {
          continue
        }
        let keywords = @reglib.strings_of(doc, "keywords")
        let mut hit = false
        for k in keywords {
          if k == kw {
            hit = true
            break
          }
        }
        if hit {
          qrels.set(id, 2)
        }
      }
    DependsOn(target) =>
      for doc in docs {
        let id = @reglib.str_of(doc, "id")
        if id == "" {
          continue
        }
        // Depending directly on the target is the strongest signal (grade 2).
        // Depending on it transitively through any declared dependency is
        // weaker evidence (grade 1)... except we cannot see other packages'
        // edges here, so grade 1 is reserved for packages whose own name
        // shares the target's basename (e.g. someone else's "async").
        let deps = @reglib.strings_of(doc, "deps")
        let mut grade = 0
        for d in deps {
          if d == target {
            grade = 2
            break
          }
        }
        if grade == 0 {
          let base = basename(target)
          if !base.is_empty() && basename(id) == base {
            grade = 1
          }
        }
        if grade > 0 {
          qrels.set(id, grade)
        }
      }
    NamePart(word) =>
      for doc in docs {
        let id = @reglib.str_of(doc, "id")
        if id == "" {
          continue
        }
        // The title field is the word-split package name, so a title token
        // match is exactly "this word is part of the package's name".
        let mut grade = 0
        for token in @reglib.str_of(doc, "title").split(" ") {
          if token == word {
            grade = 2
            break
          }
        }
        if grade > 0 {
          qrels.set(id, grade)
        }
      }
  }
  let _ = index
  qrels
}

///|
fn basename(name : String) -> String {
  match name.find("/") {
    Some(i) => name[i + 1:].to_owned()
    None => name
  }
}
