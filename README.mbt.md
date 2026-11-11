# moonseek

**Embedded full-text search engine in pure MoonBit.** Inverted index, BM25 ranking, dictionary-free Chinese tokenization, fuzzy search, faceted filtering, server-side highlighting, crash-safe WAL — runs on native, WebAssembly and JavaScript.

纯 MoonBit 实现的嵌入式全文搜索引擎：倒排索引、BM25、免词典中文分词、模糊搜索、分面过滤、服务端高亮、WAL 崩溃恢复，支持 native / WASM / JS 三端。

**▶ Live demo: [naiwaniubi.github.io/moonseek](https://naiwaniubi.github.io/moonseek/)** — searches **all 3,698 packages on mooncakes.io** in your browser. No server, no network requests after load. Also: drop your own files in and index them live, and read the measured quality/ablation report.

[![CI](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml/badge.svg)](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-v0.6.0-6f42c1.svg)](https://mooncakes.io/packages/NaIWaniubi/moonseek)
[![tests](https://img.shields.io/badge/tests-259%20native%20%C2%B7%20242%20wasm--gc-3fb950.svg)](#testing)

![moonseek demo](docs/demo-screenshot.png)

## Why moonseek

MoonBit's ecosystem has HTTP servers, crypto and database drivers — but no tantivy/Lucene-class embedded search engine. moonseek fills that gap with a single dependency-light library that works everywhere MoonBit compiles, including **inside the browser via WasmGC**.

## Features

- **Inverted index** with per-field weights (e.g. title ×3, body ×1)
- **BM25 ranking** with configurable `k1` / `b`
- **Chinese + English tokenization**: Latin words with stop-word removal; CJK overlapping bigrams (Lucene CJKAnalyzer strategy) — no dictionary needed
- **Rich query syntax**: `term`, `"exact phrase"`, `"a b"~3` (sloppy phrase: up to 3 tokens between terms), `AND` / `OR` / `NOT`, `field:term`, `prefix*`, parentheses, implicit AND
- **Fuzzy search**: Levenshtein / Damerau-Levenshtein edit distance with early-exit bounded DP; **BK-tree** for sub-linear lookup (13–1780× faster than linear scan on a 24k-term vocabulary)
- **Did-you-mean**: frequency-weighted spelling correction (`suggest`)
- **Faceted search**: exact-match facet fields, AND/OR filters, per-facet value counts, offset pagination (`search_faceted`)
- **Ranking control**: configurable sort (`search_sorted`), cursor pagination (`search_after`), per-term BM25 breakdown (`explain`)
- **Server-side highlighting**: `highlight` / `snippet` with HTML escaping, CJK-aware codepoint spans, overlap merging, densest-window extraction
- **Stored fields**: original texts kept in the index, retrievable via `get_document` / `get_field`, survive snapshots
- **Segmented index**: immutable segments + tiered merge policy + cross-segment search with latest-version-wins (`SegmentedIndex`)
- **Write-ahead log**: CRC-framed entries, torn-tail recovery, durable add + atomic checkpoint + crash-safe reopen (native)
- **Crash-safe persistence**: versioned snapshot + CRC-32 checksum; atomic save (temp file → fsync → rename); torn/corrupt files are rejected, never silently loaded
- **Portable**: pure MoonBit core (no FFI in the engine); native file store via `moonbitlang/async`; browser export via WasmGC + js-string builtins. **One snapshot format, two backends**: an index built by the native binary loads byte-for-byte into the browser's wasm-gc build
- **Measured quality, not just latency**: NDCG@10 / MRR@10 / Recall@20 over 3,698 real packages with a 6-way ablation ([docs/quality.md](docs/quality.md))
- **Document lifecycle**: add, replace (same id), delete

## How it works

```mermaid
flowchart LR
  T[text] --> A[Analyzer<br/>Latin words + CJK bigrams]
  A --> I[Inverted index<br/>field → term → postings<br/>doc, freq, positions]
  Q[query string] --> P[Lexer → parser<br/>term / phrase / prefix / AND OR NOT]
  P --> E[Evaluator<br/>ascending doc arrays<br/>merge-based set ops]
  I --> E
  E --> K[Top-K selection<br/>score desc, id asc]
  K --> H[hits]
  I --> S[Snapshot MSK3<br/>CRC-32 frame]
  I --> W[WAL<br/>torn-tail recovery]
  I --> F[Facets<br/>filter + aggregation]
  B[Browser<br/>WasmGC + js-string] -.-> I
```

## Quick start

```moonbit nocheck
let index = @moonseek.Index::new([
  { name: "title", weight: 3.0 },
  { name: "body", weight: 1.0 },
])

index.add({
  id: "doc1",
  fields: [
    ("title", "全文搜索引擎"),
    ("body", "倒排索引是搜索引擎的核心，BM25 负责排序。"),
  ],
})
index.add({
  id: "doc2",
  fields: [("title", "MoonBit"), ("body", "A fast language for WebAssembly")],
})

let hits = index.search("搜索引擎")        // [{ id: "doc1", score: … }]
let hits2 = index.search("title:moonbit")  // field-scoped
let hits3 = index.search("\"memory safety\" OR wasm*")  // phrase + prefix

// Persist (native)
index.save("index.msk")
let restored = @moonseek.Index::load("index.msk")

// Or portable bytes (works on every backend)
let image : Bytes = index.to_bytes()
let restored2 = @moonseek.Index::from_bytes(image)
```

## CLI

```bash
moon run cmd/main -- index ./docs --index index.msk   # index .txt/.md files
moon run cmd/main -- search "搜索引擎" --index index.msk
moon run cmd/main -- search "title:rust" --limit 5
moon run cmd/main -- info --index index.msk
```

## Browser demo

A complete search engine running inside your browser — no server, no network:

```bash
moon build --target wasm-gc
cp _build/wasm-gc/debug/build/web/web.wasm demo/web.wasm
cd demo && python -m http.server 8000
# open http://localhost:8000 (Chrome / Edge with WasmGC + js-string builtins)
```

The demo does three things, all in the browser:

1. **Searches the real registry.** Every one of the **3,698 packages published on mooncakes.io** (22,837 versions) is indexed — package names, author-written keywords, descriptions, and dependency edges. The index is built by the *native* binary into a 1.37 MB `MSK3` snapshot and loaded by the *wasm-gc* build, which is the strongest evidence that the format is portable. Loading takes ~200 ms; the median query over a 12-query mix is **0.20 ms**.
2. **Indexes your own files.** Drag in `.txt` / `.md` / `.json` / `.csv` / `.log` files (or paste text) and they are parsed, tokenized and searchable immediately, with the whole index persistable to IndexedDB as one snapshot blob and reloadable without re-parsing.
3. **Shows its own quality.** A live benchmark measures query-latency percentiles and the latency-vs-index-size curve in your browser, next to the ablation table from `tools/eval`: the same corpus and queries under six scoring configurations, so you can see which mechanism is worth how much NDCG.

Results use **server-side highlighting** (the WASM engine produces escaped HTML with CJK-aware `<mark>` spans), misspelled queries get **did-you-mean suggestions** and **fuzzy fallback**, and every hit can expand into its **BM25 score breakdown**.

## Performance

`moon bench --target native --release`, 1000 synthetic documents (~80 tokens each), AMD Ryzen 7 7435H:

Small corpus (`moon bench`, 1000 synthetic docs, mean +/- sigma):

| Operation | Time |
|---|---|
| Index 1000 docs (with stored fields) | 85.8 ms +/- 6.2 |
| Term query (top-10) | 262 us +/- 12 |
| Phrase query (top-10) | 1.01 ms +/- 0.24 |
| Snapshot save + load | 45.3 ms +/- 2.7 |

Stress test (`bench/stress`, 20,000 docs / 8.57 MB text / 23,782 terms, release). Build is the
median of 4 timed runs; queries are p50 of 200 samples, `limit=10`:

| Operation | Time |
|---|---|
| Index build | 2.73 s -> **7,320 docs/s** (median of 4) |
| Selective term (df 285) | **0.06 ms** |
| Field-scoped term (df 732) | 0.13 ms |
| Saturated term (df 4,021) | 2.14 ms |
| Chinese bigram (df 4,113) | 2.19 ms |
| Boolean query | 4.50 ms |
| Exact phrase | 6.25 ms |
| Sloppy phrase `"a b"~3` | 7.89 ms |
| Prefix query | 2.13 ms |
| Facet filter + aggregation (3,055 matches) | 14.0 ms |
| Fuzzy lookup, 23.8k terms | linear 37-46 ms -> **BK-tree 0.07-2.7 ms** (17-491x) |
| Snapshot 17.6 MB: serialize / load | 0.68 s / 0.75 s |

Browser (WasmGC, the 3,698-package registry snapshot): 206 KB binary, snapshot load ~200 ms, median
query **0.20 ms**, p90 0.2-0.3 ms, snapshot export ~200-315 ms.

Full methodology, per-shape ranges and an explicit list of what is *not* measured:
[docs/benchmark.md](docs/benchmark.md).

## Architecture

```
token.mbt      Analyzer: Latin words + CJK bigrams, positions
index.mbt      Inverted index, field stats, BM25, stored fields
query.mbt      Lexer → recursive-descent parser → evaluator
fuzzy.mbt      Levenshtein/Damerau distance, fuzzy search
suggest.mbt    Frequency-weighted did-you-mean
highlight.mbt  Server-side highlight/spans/snippet (codepoint offsets)
facet.mbt      Facet values, filters, aggregations, pagination
bktree.mbt     BK-tree for sub-linear fuzzy lookup
explain.mbt    BM25 breakdown, sort orders, cursor pagination
segment.mbt    SegmentedIndex: immutable segments + tiered merge
wal.mbt        CRC-framed write-ahead log (portable byte layer)
wal_native.mbt Durable add/checkpoint/crash recovery (native)
codec.mbt      Varint / UTF-8 / double / CRC-32 primitives
snapshot.mbt   MSK3 format: versioned payload + checksum + stored fields + facets
store.mbt      Native atomic file persistence (async/fs)
web/           Browser exports (#export_name, js-string builtins)
cmd/main/      CLI: index / search / info
examples/      Runnable examples (basic, persistence)
demo/          Single-page browser demo (60 docs, benchmarks, inspector)
```

See [docs/architecture.md](docs/architecture.md) for design details and the snapshot format specification.

- [docs/benchmark.md](docs/benchmark.md) — performance whitepaper (stress numbers, methodology, limitations)
- [docs/comparison.md](docs/comparison.md) — feature matrix vs tantivy / Lucene / bleve

## Testing

```bash
moon test                    # 259 tests (native), 242 (wasm-gc / js)
moon test --target wasm-gc
moon test --target js
moon bench --release         # benchmarks
moon coverage analyze        # coverage report
moon run bench/stress --target native --release   # 20k-doc stress benchmark
```

Tests cover tokenization, boolean/phrase/prefix/fuzzy queries, BM25 ordering, spelling correction, highlighting spans and HTML escaping, segment merge correctness, WAL torn-tail recovery, snapshot roundtrips, corruption/truncation detection, crash-safe file persistence, and quickcheck properties (roundtrip, varint, positions, delete exclusion).

## Roadmap

- [x] Segment merging & incremental indexing
- [x] Result highlighting API
- [x] Fuzzy / edit-distance queries
- [x] Did-you-mean spelling correction
- [x] Write-ahead log with crash recovery
- [x] Faceted search & aggregations
- [x] BK-tree accelerated fuzzy matching
- [x] Score explanation, sort orders, cursor pagination
- [x] Merge-based evaluator over ascending doc arrays (no per-query score map)
- [ ] Distributed sharded search (OSC2027)

## License

Apache-2.0. Built for the MoonBit open-source ecosystem.