///|
/// moonseek CLI: index text files, search them, inspect the index.
/// Usage:
///   moonseek index <dir> [--index PATH]     index .txt/.md files under <dir>
///   moonseek search <query> [--index PATH] [--limit N]
///   moonseek info [--index PATH]
async fn main {
  let command = @argparse.Command(
    "moonseek",
    about="Embedded full-text search engine (pure MoonBit).",
    subcommands=[
      @argparse.Command(
        "index",
        about="Index .txt/.md files from a directory into a snapshot.",
        positionals=[PositionArg("dir", about="directory to index")],
        options=[
          OptionArg(
            "index",
            long="index",
            default_values=["index.msk"],
            about="snapshot path (default: index.msk)",
          ),
        ],
      ),
      @argparse.Command(
        "search",
        about="Search an index snapshot.",
        positionals=[
          PositionArg(
            "query",
            about="query: terms, \"phrase\", AND/OR/NOT, field:term, prefix*",
          ),
        ],
        options=[
          OptionArg(
            "index",
            long="index",
            default_values=["index.msk"],
            about="snapshot path (default: index.msk)",
          ),
          OptionArg(
            "limit",
            long="limit",
            default_values=["10"],
            about="max hits (0 = unlimited)",
          ),
        ],
      ),
      @argparse.Command("info", about="Show index statistics.", options=[
        OptionArg(
          "index",
          long="index",
          default_values=["index.msk"],
          about="snapshot path (default: index.msk)",
        ),
      ]),
    ],
  )
  let matches = command.parse()
  match matches.subcommand {
    Some(("index", sub)) => {
      let dir = sub.values["dir"][0]
      let path = sub.values["index"][0]
      run_index(dir, path)
    }
    Some(("search", sub)) => {
      let query = sub.values["query"][0]
      let path = sub.values["index"][0]
      let limit = @string.parse_int(sub.values["limit"][0]) catch { _ => 10 }
      run_search(path, query, limit)
    }
    Some(("info", sub)) => run_info(sub.values["index"][0])
    _ => println("use --help for usage")
  }
}

///|
fn schema() -> Array[@moonseek.FieldSchema] {
  [{ name: "title", weight: 3.0, }, { name: "body", weight: 1.0, }]
}

///|
async fn run_index(dir : String, path : String) -> Unit {
  let index = @moonseek.Index::new(schema())
  let entries = @fs.readdir(dir, sort=true) catch {
    e => {
      println("cannot read directory \{dir}: \{e}")
      return ()
    }
  }
  let mut count = 0
  for name in entries {
    if name.has_suffix(".txt") || name.has_suffix(".md") {
      let file_path = dir + "/" + name
      let content = @fs.read_file(file_path) catch { _ => continue }
      let text = content.text() catch { _ => continue }
      // First non-empty line becomes the title; the rest is the body.
      let lines = text.split("\n")
      let mut title = name
      let mut body_start = 0
      let line_arr = lines.to_array()
      for i in 0..<line_arr.length() {
        let trimmed = line_arr[i].to_owned()
        if !trimmed.is_blank() {
          title = trimmed
          body_start = i + 1
          break
        }
      }
      let body_parts : Array[String] = []
      for i in body_start..<line_arr.length() {
        body_parts.push(line_arr[i].to_owned())
      }
      index.add({
        id: name,
        fields: [("title", title), ("body", body_parts.join("\n"))],
      })
      count += 1
    }
  }
  index.save(path) catch {
    e => {
      println("save failed: \{e}")
      return ()
    }
  }
  println("indexed \{count} documents -> \{path} (\{index.term_count()} terms)")
}

///|
async fn run_search(path : String, query : String, limit : Int32) -> Unit {
  let index = @moonseek.Index::load(path) catch {
    e => {
      println("cannot load index: \{e}")
      return ()
    }
  }
  let hits = index.search(query, limit~) catch {
    e => {
      println("query error: \{e}")
      return ()
    }
  }
  if hits.is_empty() {
    println("no results")
    return ()
  }
  let mut rank = 1
  for hit in hits {
    println("\{rank}. \{hit.id}  (score \{hit.score})")
    rank += 1
  }
}

///|
async fn run_info(path : String) -> Unit {
  let index = @moonseek.Index::load(path) catch {
    e => {
      println("cannot load index: \{e}")
      return ()
    }
  }
  println("documents: \{index.doc_count()}")
  println("terms:     \{index.term_count()}")
  println("snapshot:  \{index.to_bytes().length()} bytes")
}
