# moonseek

**Embedded full-text search engine in pure MoonBit.** Inverted index, BM25 ranking, dictionary-free Chinese tokenization, crash-safe snapshots — runs on native, WebAssembly and JavaScript.

纯 MoonBit 实现的嵌入式全文搜索引擎：倒排索引、BM25 排序、免词典中文分词、崩溃安全快照，支持 native / WASM / JS 三端。

[![CI](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml/badge.svg)](https://github.com/NaIWaniubi/moonseek/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## Why moonseek

MoonBit's ecosystem has HTTP servers, crypto and database drivers — but no tantivy/Lucene-class embedded search engine. moonseek fills that gap with a single dependency-light library that works everywhere MoonBit compiles, including **inside the browser via WasmGC**.

## Features

- **Inverted index** with per-field weights (e.g. title ×3, body ×1)
- **BM25 ranking** with configurable `k1` / `b`
- **Chinese + English tokenization**: Latin words with stop-word removal; CJK overlapping bigrams (Lucene CJKAnalyzer strategy) — no dictionary needed
- **Rich query syntax**: `term`, `"exact phrase"`, `AND` / `OR` / `NOT`, `field:term`, `prefix*`, parentheses, implicit AND
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

The demo indexes 15 documents (MoonBit docs + 论语/道德经) in ~6 ms and answers Chinese, English, phrase and field queries with highlighting.

## Performance

`moon bench --target native --release`, 1000 synthetic documents (~80 tokens each), AMD Ryzen 7 7435H:

| Operation | Time |
|---|---|
| Index 1000 docs | ~89 ms |
| Term query (top-10) | ~1.0 ms |
| Phrase query (top-10) | ~2.9 ms |
| Snapshot save+load | ~30 ms |

## Architecture

```
token.mbt     Analyzer: Latin words + CJK bigrams, positions
index.mbt     Inverted index, field stats, BM25 scoring
query.mbt     Lexer → recursive-descent parser → evaluator
codec.mbt     Varint / UTF-8 / double / CRC-32 primitives
snapshot.mbt  MSK1 format: versioned payload + checksum
store.mbt     Native atomic file persistence (async/fs)
web/          Browser exports (#export_name, js-string builtins)
cmd/main/     CLI: index / search / info
demo/         Single-page browser demo
```

See [docs/architecture.md](docs/architecture.md) for design details and the snapshot format specification.

## Testing

```bash
moon test                    # 43 tests (native), 39 (wasm-gc / js)
moon test --target wasm-gc
moon test --target js
moon bench --release         # benchmarks
```

Tests cover tokenization, boolean/phrase/prefix queries, BM25 ordering, snapshot roundtrips, corruption/truncation detection, and crash-safe file persistence.

## Roadmap

- [ ] Segment merging & incremental indexing
- [ ] Result highlighting API
- [ ] Fuzzy / edit-distance queries
- [ ] Distributed sharded search (OSC2027)

## License

Apache-2.0. Built for the MoonBit open-source ecosystem.