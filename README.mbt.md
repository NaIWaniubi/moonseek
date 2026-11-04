# moonseek

**Embedded full-text search engine in pure MoonBit.** Inverted index, BM25 ranking, dictionary-free Chinese tokenization, fuzzy search, faceted filtering, server-side highlighting, crash-safe WAL — runs on native, WebAssembly and JavaScript.

纯 MoonBit 实现的嵌入式全文搜索引擎：倒排索引、BM25、免词典中文分词、模糊搜索、分面过滤、服务端高亮、WAL 崩溃恢复，支持 native / WASM / JS 三端。

[![CI](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml/badge.svg)](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## Why moonseek

MoonBit's ecosystem has HTTP servers, crypto and database drivers — but no tantivy/Lucene-class embedded search engine. moonseek fills that gap with a single dependency-light library that works everywhere MoonBit compiles, including **inside the browser via WasmGC**.

## Features

- **Inverted index** with per-field weights (e.g. title ×3, body ×1)
- **BM25 ranking** with configurable `k1` / `b`
- **Chinese + English tokenization**: Latin words with stop-word removal; CJK overlapping bigrams (Lucene CJKAnalyzer strategy) — no dictionary needed
- **Rich query syntax**: `term`, `"exact phrase"`, `AND` / `OR` / `NOT`, `field:term`, `prefix*`, parentheses, implicit AND
- **Fuzzy search**: Levenshtein / Damerau-Levenshtein edit distance with early-exit bounded DP; **BK-tree** for sub-linear lookup (13–1780× faster than linear scan on a 24k-term vocabulary)
- **Did-you-mean**: frequency-weighted spelling correction (`suggest`)
- **Faceted search**: exact-match facet fields, AND/OR filters, per-facet value counts, offset pagination (`search_faceted`)
- **Ranking control**: configurable sort (`search_sorted`), cursor pagination (`search_after`), per-term BM25 breakdown (`explain`)
- **Server-side highlighting**: `highlight` / `snippet` with HTML escaping, CJK-aware codepoint spans, overlap merging, densest-window extraction
- **Stored fields**: original texts kept in the index, retrievable via `get_document` / `get_field`, survive snapshots
- **Segmented index**: immutable segments + tiered merge policy + cross-segment search with latest-version-wins (`SegmentedIndex`)
- **Write-ahead log**: CRC-framed entries, torn-tail recovery, durable add + atomic checkpoint + crash-safe reopen (native)
- **Crash-safe persistence**: versioned snapshot + CRC-32 checksum; atomic save (temp file → fsync → rename); torn/corrupt files are rejected, never silently loaded
- **Portable**: pure MoonBit core (no FFI in the engine); native file store via `moonbitlang/async`; browser export via WasmGC + js-string builtins
- **Document lifecycle**: add, replace (same id), delete

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

The demo indexes 60 bilingual documents (MoonBit docs + Chinese classics + CS topics) in ~20 ms. Results use **server-side highlighting** (the WASM engine produces escaped HTML with CJK-aware `<mark>` spans), misspelled queries get **did-you-mean suggestions** and **fuzzy fallback**, and a live panel shows benchmark numbers and per-field term frequencies.

## Performance

`moon bench --target native --release`, 1000 synthetic documents (~80 tokens each), AMD Ryzen 7 7435H:

Small corpus (`moon bench`, 1000 synthetic docs):

| Operation | Time |
|---|---|
| Index 1000 docs (with stored fields) | ~135 ms |
| Term query (top-10) | ~2.4 ms |
| Phrase query (top-10) | ~1.8 ms |
| Snapshot save+load (with stored fields) | ~75 ms |

Stress test (`bench/stress`, 20,000 docs / 8.5 MB text / 23.8k terms, AMD Ryzen 7 7435H, release):

| Operation | Time |
|---|---|
| Index build | ~6.7 s (≈3,000 docs/s) |
| Selective term query (df ≈ 300) | **~0.02 ms** |
| Prefix query | ~17 ms (dominated by scoring the matched terms) |
| Saturated term (matches every doc) | ~13 ms |
| Phrase query | ~18 ms |
| Facet filter + aggregation (3k matches) | ~21 ms |
| Fuzzy lookup, 24k terms | linear ~100 ms → **BK-tree 0.05–12 ms** |
| Snapshot 17 MB: serialize / load | ~2.4 s / ~1.7 s |

Browser (WasmGC, 60 bilingual docs): index ~25 ms, query 0.1–11 ms, snapshot 44 KB.

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

## Testing

```bash
moon test                    # 217 tests (native), 203 (wasm-gc / js)
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
- [ ] Postings-iterator evaluator (avoid materializing per-query score maps)
- [ ] Distributed sharded search (OSC2027)

## License

Apache-2.0. Built for the MoonBit open-source ecosystem.