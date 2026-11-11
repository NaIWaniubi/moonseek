///|
/// Retrieval-quality benchmark: runs every eval query against every ablation
/// configuration, computes NDCG@10 / MRR@10 / Recall@20, and writes a
/// Markdown report plus a JSON sidecar.
///
/// Usage:
///   moonseek-eval <registry.json> <out.md> [--json out.json]
///
/// Everything here is deterministic: same corpus + same queries -> same
/// numbers, so the report can be regenerated in CI and diffed.

///|
/// One configuration's aggregate result over all queries.
struct ConfigResult {
  config : Config
  ndcg : Double
  mrr : Double
  recall : Double
  /// Per-query NDCG@10, in eval_queries() order.
  per_query : Array[Double]
  query_ms : Double
}

///|
async fn main {
  let argv = @env.args()
  let paths : Array[String] = []
  let mut json_path : String? = None
  let mut i = 1
  while i < argv.length() {
    if argv[i] == "--json" && i + 1 < argv.length() {
      json_path = Some(argv[i + 1])
      i += 2
    } else {
      paths.push(argv[i])
      i += 1
    }
  }
  if paths.length() < 2 {
    println("usage: moonseek-eval <registry.json> <out.md> [--json out.json]")
    return ()
  }
  let raw = @fs.read_file(paths[0]) catch {
    e => {
      println("cannot read \{paths[0]}: \{e}")
      return ()
    }
  }
  let text = raw.text() catch {
    e => {
      println("cannot decode registry json: \{e}")
      return ()
    }
  }
  let json = @json.parse(text) catch {
    e => {
      println("bad json: \{e}")
      return ()
    }
  }
  let docs = match json {
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
  let queries = eval_queries()
  // Labels depend only on the corpus, except the NamePart rule which reads
  // the indexed title field; build them once against the reference index.
  let reference = build_for(configs()[0], docs)
  let qrels : Array[@hashmap.HashMap[String, Int32]] = []
  for q in queries {
    qrels.push(build_qrels(reference, docs, q))
  }
  let results : Array[ConfigResult] = []
  for config in configs() {
    let index = build_for(config, docs)
    let per_query : Array[Double] = []
    let mut ndcg_sum = 0.0
    let mut mrr_sum = 0.0
    let mut recall_sum = 0.0
    let mut total_ms = 0.0
    for qi in 0..<queries.length() {
      let q = queries[qi]
      let gains = qrels[qi]
      // limit=0 so Recall@20 sees beyond the ten results the UI shows.
      let started = @env.now()
      let hits = index.search(q.text, limit=0) catch {
        e => {
          println("query failed: \{q.text}: \{e}")
          continue
        }
      }
      total_ms += (@env.now() - started).to_double()
      let ranked = hits.map(fn(h) { h.id })
      let ndcg = ndcg_at(gains, ranked, 10)
      ndcg_sum += ndcg
      mrr_sum += mrr_at(gains, ranked, 10)
      recall_sum += recall_at(gains, ranked, 20)
      per_query.push(ndcg)
    }
    let n = queries.length().to_double()
    results.push({
      config,
      ndcg: ndcg_sum / n,
      mrr: mrr_sum / n,
      recall: recall_sum / n,
      per_query,
      query_ms: total_ms / n,
    })
  }
  let markdown = render_report(queries, qrels, results, reference)
  @fs.write_file(paths[1], @utf8.encode(markdown)) catch {
    e => {
      println("cannot write \{paths[1]}: \{e}")
      return ()
    }
  }
  if json_path is Some(p) {
    @fs.write_file(p, @utf8.encode(render_json(results, queries))) catch {
      e => println("cannot write \{p}: \{e}")
    }
  }
  println("queries: \{queries.length()}, documents: \{reference.doc_count()}")
  for r in results {
    println(
      "\{pad_end(r.config.name, 16)} NDCG@10 \{fmt(r.ndcg)}  MRR@10 \{fmt(r.mrr)}  Recall@20 \{fmt(r.recall)}  \{fmt(r.query_ms)} ms/q",
    )
  }
  println("report -> \{paths[1]}")
}

///|
/// Fixed four-decimal formatting (no exponent, no locale surprises).
fn fmt(x : Double) -> String {
  let scaled = (x * 10000.0).round().to_int()
  let whole = scaled / 10000
  let frac = (scaled % 10000).abs()
  let frac_str = frac.to_string()
  let padded = if frac_str.length() < 4 {
    zeros(4 - frac_str.length()) + frac_str
  } else {
    frac_str
  }
  "\{whole}.\{padded}"
}

///|
fn zeros(n : Int32) -> String {
  let mut out = ""
  let mut i = 0
  while i < n {
    i += 1
    out = out + "0"
  }
  out
}

///|
fn pad_end(s : String, width : Int32) -> String {
  if s.length() >= width {
    return s
  }
  s + " ".repeat(width - s.length())
}

///|
/// Markdown report: headline table, deltas, per-query table, and an explicit
/// note about what the labels are (and are not).
fn render_report(
  queries : Array[EvalQuery],
  qrels : Array[@hashmap.HashMap[String, Int32]],
  results : Array[ConfigResult],
  reference : @moonseek.Index,
) -> String {
  let lines : Array[String] = []
  lines.push("# Retrieval quality on the mooncakes registry\n")
  lines.push(
    "\{reference.doc_count()} real published packages, \{queries.length()} queries, labels derived from the corpus itself. Regenerate with `moon run tools/eval --target native --release -- demo/registry.json docs/quality.md`.\n",
  )
  lines.push("## What the labels are\n")
  lines.push(
    "**These are derived judgments, not human assessments.** Each query carries its own relevance rule taken from the data: a keyword query grades every package that declares that exact keyword at 2; a dependency query grades direct dependents at 2 and packages merely sharing the dependency's basename at 1; a name-part query grades packages whose name contains that word at 2. The rules are fixed before any retrieval happens and never look at the retriever's output, so the numbers are comparable *across configurations in this table*. They are not comparable to published BEIR or MS MARCO scores and this report makes no such claim.\n",
  )
  lines.push("## Aggregate\n")
  lines.push(
    "| configuration | NDCG@10 | MRR@10 | Recall@20 | ms/query | what it isolates |",
  )
  lines.push("|---|---|---|---|---|---|")
  for r in results {
    lines.push(
      "| `\{r.config.name}` | **\{fmt(r.ndcg)}** | \{fmt(r.mrr)} | \{fmt(r.recall)} | \{fmt(r.query_ms)} | \{r.config.isolates} |",
    )
  }
  lines.push("")
  let base = results[0]
  lines.push("### Change against the shipped configuration\n")
  lines.push("| configuration | dNDCG@10 | dMRR@10 | dRecall@20 |")
  lines.push("|---|---|---|---|")
  for r in results {
    if r.config.name == base.config.name {
      continue
    }
    lines.push(
      "| `\{r.config.name}` | \{delta(r.ndcg, base.ndcg)} | \{delta(r.mrr, base.mrr)} | \{delta(r.recall, base.recall)} |",
    )
  }
  lines.push("")
  lines.push("## Per query (NDCG@10)\n")
  let mut header = "| query | relevance rule | relevant docs |"
  let mut sep = "|---|---|---|"
  for r in results {
    header = header + " \{r.config.name} |"
    sep = sep + "---|"
  }
  lines.push(header)
  lines.push(sep)
  for qi in 0..<queries.length() {
    let q = queries[qi]
    let mut relevant = 0
    for (_, g) in qrels[qi].iter() {
      if g > 0 {
        relevant += 1
      }
    }
    let mut row = "| `\{q.text}` | \{judgement_label(q.judgement)} | \{relevant} |"
    for r in results {
      row = row + " \{fmt(r.per_query[qi])} |"
    }
    lines.push(row)
  }
  lines.push("")
  lines.push("## Reading the table\n")
  lines.push(
    "- `desc-only` and `title-only` are the baselines that matter: each is what a naive implementation ships. The gap between them and the shipped configuration is the value the index adds.",
  )
  lines.push(
    "- `metadata-only` answers a cost question. Prose is the bulk of the index; if dropping it barely moves the numbers, the index is paying for text nobody searches.",
  )
  lines.push(
    "- `no-length-norm` sets BM25's `b` to 0. If it ties the shipped configuration, length normalization is not earning its complexity on this corpus - a result worth reporting either way.",
  )
  lines.push(
    "- Query latency here is single-run wall clock on one machine. The stress benchmark is the place for latency claims, not this table.",
  )
  lines.push("")
  lines.join("\n")
}

///|
fn judgement_label(j : Judgement) -> String {
  match j {
    Keywords(kw) => "keyword `\{kw}`"
    DependsOn(d) => "depends on `\{d}`"
    NamePart(w) => "name contains `\{w}`"
  }
}

///|
fn delta(value : Double, base : Double) -> String {
  if base == 0.0 {
    return "n/a"
  }
  let rel = (value - base) / base * 100.0
  let scaled = (rel.abs() * 10.0).round().to_int()
  let sign = if rel >= 0.0 { "+" } else { "-" }
  "\{sign}\{scaled / 10}.\{scaled % 10}%"
}

///|
/// JSON sidecar, so the numbers can be plotted or diffed in CI.
fn render_json(
  results : Array[ConfigResult],
  queries : Array[EvalQuery],
) -> String {
  let root : Map[String, Json] = Map([])
  root["queries"] = Json::array(queries.map(fn(q) { @json.to_json(q.text) }))
  let rows : Array[Json] = []
  for r in results {
    let row : Map[String, Json] = Map([])
    row["config"] = @json.to_json(r.config.name)
    row["ndcg@10"] = @json.to_json(r.ndcg)
    row["mrr@10"] = @json.to_json(r.mrr)
    row["recall@20"] = @json.to_json(r.recall)
    row["ms_per_query"] = @json.to_json(r.query_ms)
    rows.push(Json::object(row))
  }
  root["results"] = Json::array(rows)
  Json::object(root).stringify(indent=2)
}
