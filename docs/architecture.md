# moonseek Architecture

## Design goals

1. **Pure MoonBit core** — the engine (tokenize → index → query → score) uses no FFI, so it compiles unchanged to native, wasm-gc and js.
2. **Crash safety by construction** — a snapshot is either complete and checksummed or rejected; the file store never overwrites the live snapshot in place.
3. **Small, auditable surface** — ~2k LOC, one runtime dependency (`moonbitlang/async`, native store only).

## Pipeline

```
text ──► Analyzer ──► Token{term, position}
                          │
                          ▼
                    Inverted Index          Query string
                    field → term → [Posting]     │
                          │                      ▼
                          │                 Lexer → Parser → Query AST
                          │                      │
                          └──────► Evaluator ◄───┘
                                      │
                                      ▼
                              doc → score (BM25)
                                      │
                                      ▼
                              sorted Hit[] (id, score)
```

## Tokenization (`token.mbt`)

- Latin runs: split on non-word chars, ASCII-lowercased, default English stop words removed.
- CJK runs (Unified Ideographs, Ext-A, kana, hangul): overlapping **bigrams** — `全文搜索` → `全文`, `文搜`, `搜索`. Single-char runs emit a unigram. This is Lucene's CJKAnalyzer strategy: no dictionary, no model, works offline, and phrase queries still work because positions are contiguous.
- Every token carries a stream position, shared across scripts, enabling cross-script phrase queries.

## Index (`index.mbt`)

- Documents get internal numbers; external ids map both ways. Re-adding an id tombstones the old number (postings stay, stats are removed, queries skip deleted docs).
- Per field: `term → Posting[]` where `Posting = {doc, freq, positions[]}`.
- Per field stats: `doc → token length` + total length, maintained incrementally for BM25's `avgdl`.

## Scoring (`index.mbt`)

BM25 with IDF `ln(1 + (N − df + 0.5)/(df + 0.5))`, tf saturation `k1=1.2`, length normalization `b=0.75`, multiplied by the field weight. Phrase hits are scored as a pseudo-term whose frequency is the phrase occurrence count.

## Query language (`query.mbt`)

```
or_expr   := and_expr (OR and_expr)*
and_expr  := not_expr ((AND)? not_expr)*      -- implicit AND
not_expr  := primary (NOT primary)*
primary   := '(' or_expr ')' | '"' phrase '"' | word
word      := [field:]term | [field:]prefix* | *
```

A bare CJK word analyzes to multiple bigrams and is treated as a phrase. Evaluation returns `doc → score` maps; AND intersects (summing scores), OR unions, NOT subtracts.

## Snapshot format (`snapshot.mbt`, `codec.mbt`)

```
┌────────┬──────────────────────────┬──────────────┐
│ "MSK1" │ payload                  │ crc32 (u32le)│
└────────┴──────────────────────────┴──────────────┘
payload := varint version=1
           schema[]  (name, weight:f64)
           analyzer flags, bm25 k1/b (f64)
           doc ids[]
           deleted doc numbers[]
           per-field stats (doc → length)
           per-field terms (sorted) → postings
             posting := doc, freq, positions (delta-varint)
```

- Integers: unsigned LEB128 varints. Strings: varint length + strict UTF-8. Doubles: IEEE-754 little-endian.
- CRC-32 (IEEE, zlib polynomial) covers the payload; readers verify before parsing.
- Terms are sorted for deterministic output — the same index always produces byte-identical snapshots.
- Unknown versions, bad magic, truncation and checksum mismatches all raise; a corrupt snapshot is never partially loaded.

## File store (`store.mbt`, native only)

`save`: write `path.tmp` with `sync=Data` (fdatasync) → `rename` over `path`. A crash leaves either the old snapshot or the new one; a leftover `.tmp` is ignored on load. `load` verifies the CRC before returning an index. `load_or_create` creates a fresh index only when the file is absent — a corrupt file is an error, not a silent reset.

## Browser exports (`web/`)

`pkgtype(kind: "foreign_library")` + `#export_name` exposes `ms_init / ms_add / ms_search / ms_save / ms_load / ms_count / ms_terms`. Only stable-ABI types cross the boundary (String, Int, Bytes); search results are returned as a JSON string. With `use-js-builtin-string`, MoonBit strings are JS strings — zero-copy. The host instantiates with `{ builtins: ["js-string"], importedStringConstants: "_" }`.

## Testing strategy

- Unit tests per module; blackbox tests exercise the public API only.
- Golden query tests pin result ids and ordering.
- Snapshot tests: roundtrip equality (ids + exact scores), determinism, bit-flip detection, truncation detection, bad magic.
- Store tests: real filesystem roundtrips in temp dirs, corrupt-file rejection, no temp-file leakage.
- Benchmarks (`bench_test.mbt`): 1000-doc synthetic corpus, index/term/phrase/snapshot.