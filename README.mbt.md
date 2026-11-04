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
- **Fuzzy search**: Levenshtein / Damerau-Levenshtein edit distance with length pruning; typo-tolerant `fuzzy_search("serch")` finds "search"
- **Did-you-mean**: frequency-weighted spelling correction (`suggest`)
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

| Operation | Time |
|---|---|
| Index 1000 docs (with stored fields) | ~135 ms |
| Term query (top-10) | ~2.4 ms |
| Phrase query (top-10) | ~1.8 ms |
| Snapshot save+load (with stored fields) | ~75 ms |

Browser (WasmGC, 60 bilingual docs): index ~20 ms, average query ~250 µs, snapshot 43 KB.

## Architecture

```
token.mbt      Analyzer: Latin words + CJK bigrams, positions
index.mbt      Inverted index, field stats, BM25, stored fields
query.mbt      Lexer → recursive-descent parser → evaluator
fuzzy.mbt      Levenshtein/Damerau distance, fuzzy search
suggest.mbt    Frequency-weighted did-you-mean
highlight.mbt  Server-side highlight/spans/snippet (codepoint offsets)
segment.mbt    SegmentedIndex: immutable segments + tiered merge
wal.mbt        CRC-framed write-ahead log (portable byte layer)
wal_native.mbt Durable add/checkpoint/crash recovery (native)
codec.mbt      Varint / UTF-8 / double / CRC-32 primitives
snapshot.mbt   MSK2 format: versioned payload + checksum + stored fields
store.mbt      Native atomic file persistence (async/fs)
web/           Browser exports (#export_name, js-string builtins)
cmd/main/      CLI: index / search / info
examples/      Runnable examples (basic, persistence)
demo/          Single-page browser demo (60 docs, benchmarks, inspector)
```

See [docs/architecture.md](docs/architecture.md) for design details and the snapshot format specification.

## Testing

```bash
moon test                    # 179 tests (native), 164 (wasm-gc / js)
moon test --target wasm-gc
moon test --target js
moon bench --release         # benchmarks
moon coverage analyze        # coverage report
```

Tests cover tokenization, boolean/phrase/prefix/fuzzy queries, BM25 ordering, spelling correction, highlighting spans and HTML escaping, segment merge correctness, WAL torn-tail recovery, snapshot roundtrips, corruption/truncation detection, crash-safe file persistence, and quickcheck properties (roundtrip, varint, positions, delete exclusion).

## Roadmap

- [x] Segment merging & incremental indexing
- [x] Result highlighting API
- [x] Fuzzy / edit-distance queries
- [x] Did-you-mean spelling correction
- [x] Write-ahead log with crash recovery
- [ ] Faceted search & aggregations
- [ ] Distributed sharded search (OSC2027)

## License

Apache-2.0. Built for the MoonBit open-source ecosystem.