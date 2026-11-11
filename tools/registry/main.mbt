///|
/// Build a moonseek snapshot straight from a mooncakes registry dump.
///
/// The registry is real, messy, third-party data: 3.7k packages described by
/// their authors, in many languages, with keyword lists, dependency edges and
/// publication dates. Indexing it is a far more honest demo than a hand-picked
/// corpus, and because the snapshot format (MSK3) is byte-identical across
/// backends, the browser demo loads exactly the bytes this tool writes.
///
/// Usage:
///   moonseek-registry <registry.json> <out.msk> [--b64 out.txt]
///
/// registry.json shape (see tools/registry-corpus.mjs):
///   { "docs": [ { "id", "title", "desc", "keywords": [...],
///                 "deps": [...], "facets": [["field", ["v"]]], "meta": {...} } ] }
async fn main {
  let argv = @env.args()
  // argv[0] is the executable; everything after it are this tool's arguments.
  let paths : Array[String] = []
  let mut b64_path : String? = None
  let mut i = 1
  while i < argv.length() {
    if argv[i] == "--b64" && i + 1 < argv.length() {
      b64_path = Some(argv[i + 1])
      i += 2
    } else {
      paths.push(argv[i])
      i += 1
    }
  }
  if paths.length() < 2 {
    println(
      "usage: moonseek-registry <registry.json> <out.msk> [--b64 out.txt]",
    )
    return ()
  }
  let input_path = paths[0]
  let out_path = paths[1]
  let raw = @fs.read_file(input_path) catch {
    e => {
      println("cannot read \{input_path}: \{e}")
      return ()
    }
  }
  let text = raw.text() catch {
    e => {
      println("cannot decode \{input_path}: \{e}")
      return ()
    }
  }
  let started = @env.now()
  let json = @json.parse(text) catch {
    e => {
      println("bad json: \{e}")
      return ()
    }
  }
  let items = match json {
    Object(fields) =>
      match fields.get("docs") {
        Some(Array(a)) => a
        Some(_) => {
          println("\"docs\" is not an array")
          return ()
        }
        None => {
          println("registry json has no \"docs\" array")
          return ()
        }
      }
    _ => {
      println("registry json is not an object")
      return ()
    }
  }
  // Build through the shared library so the demo, the tool and the quality
  // benchmark always index this corpus with the same schema and weights.
  let (index, skipped) = @reglib.build_registry_index(items)
  let elapsed_ms = (@env.now() - started).to_double()
  @fs.write_file(out_path, index.to_bytes()) catch {
    e => {
      println("cannot write \{out_path}: \{e}")
      return ()
    }
  }
  let snapshot_bytes = index.to_bytes().length()
  if b64_path is Some(p) {
    @fs.write_file(p, @utf8.encode(@base64.encode(index.to_bytes()))) catch {
      e => {
        println("cannot write \{p}: \{e}")
        return ()
      }
    }
  }
  println(
    "indexed \{index.doc_count()} packages (\{skipped} skipped without an id) in \{elapsed_ms} ms",
  )
  println(
    "\{index.term_count()} distinct terms, snapshot \{snapshot_bytes} bytes -> \{out_path}",
  )
  if elapsed_ms > 0.0 {
    println(
      "build rate: \{(index.doc_count().to_double() / elapsed_ms * 1000.0).to_int()} docs/s",
    )
  }
}
