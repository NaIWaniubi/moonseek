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
│ "MSK3" │ payload                  │ crc32 (u32le)│
└────────┴──────────────────────────┴──────────────┘
payload := varint version=3
           schema[]  (name, weight:f64)
           analyzer flags, bm25 k1/b (f64)
           doc ids[]
           deleted doc numbers[] (sorted)
           stored fields[] (doc num → (name, text) pairs)   [v2+]
           facets[] (doc num → (name, values) pairs)        [v3+]
           per-field stats (doc → length)
           per-field terms (sorted) → postings
             posting := doc, freq, positions (delta-varint)
```

- Integers: unsigned LEB128 varints. Strings: varint length + strict UTF-8. Doubles: IEEE-754 little-endian.
- CRC-32 (IEEE, zlib polynomial) covers the payload; readers verify before parsing.
- Terms and deleted-doc lists are sorted for deterministic output — the same index always produces byte-identical snapshots.
- Unknown versions, bad magic, truncation and checksum mismatches all raise; a corrupt snapshot is never partially loaded.
- **Backward compatibility**: MSK1 (v1, no stored fields) and MSK2 (v2, no facets) images are still readable.

## File store (`store.mbt`, native only)

`save`: write `path.tmp` with `sync=Data` (fdatasync) → `rename` over `path`. A crash leaves either the old snapshot or the new one; a leftover `.tmp` is ignored on load. `load` verifies the CRC before returning an index. `load_or_create` creates a fresh index only when the file is absent — a corrupt file is an error, not a silent reset.

## Fuzzy search & suggestions (`fuzzy.mbt`, `suggest.mbt`)

- `levenshtein` / `damerau_levenshtein`: single-row DP over Unicode codepoints (O(min(m,n)) space); transposition counts as one edit (OSA variant).
- `fuzzy_terms`: length-prune candidates (|Δlen| > max_distance skipped), then compute distance; max_distance clamped to [0,2] (Lucene convention).
- `fuzzy_search`: per-document max score across variant terms (no double-counting), same sort/limit semantics as `search`.
- `suggest`: span-based tokenizer preserves quotes/fields/operators; corrects the first bare word with no exact match; candidates ranked by (distance asc, doc_freq desc, term asc).

## Highlighting (`highlight.mbt`)

- `analyze_with_offsets`: re-scans stored text reusing the analyzer's private predicates, producing the same terms plus `[start,end)` **codepoint** spans (not bytes, not UTF-16 units). A whitebox drift-guard test cross-validates it against the public analyzer.
- Query AST → highlight leaves (Term/Phrase/Prefix; Not's right branch and MatchAll contribute nothing). Phrase adjacency and prefix expansion are preserved, not flattened.
- Spans merge only on overlap (adjacent spans stay separate); `highlight` HTML-escapes the source and inserts tags; `snippet` picks the densest window and closes tags at window edges.

## Segmented index (`segment.mbt`)

- `SegmentedIndex` = immutable segments + one active in-memory segment. `add` writes to active; at `segment_max_docs` it freezes into the segment list.
- `search`: queries every segment, merges by external id with **latest-version-wins** (a re-added id in a newer segment supersedes older ones; tombstones never win). Scores are per-segment BM25 (IDF differs across segments); ties break by id for determinism.
- `merge`: tiered policy — rebuilds a compacted Index from the newest live version of every document (via stored fields), reducing segment count.
- Serialization: segment count + each segment's MSK2 snapshot + active segment, framed with its own CRC.

## Write-ahead log (`wal.mbt`, `wal_native.mbt`)

- Byte layer (portable): `"MWL1"` magic + framed entries (`type byte | payload | crc32`). `wal_decode` replays the complete prefix and stops at the first torn/corrupt tail — exactly "replay all complete entries" after a crash. Repeated headers (each append batch carries one) are skipped.
- Native layer: `add_durable` appends one CRC-framed entry with `create_mode=OpenOrCreate, append=true, sync=Data` **then** applies in memory. `checkpoint` writes `segments.msk.tmp` → fsync → rename → truncate WAL. `open_or_create` loads the snapshot (corrupt = error) then replays the WAL; replay is idempotent (Add replaces by id, Delete is a tombstone), so a crash between rename and truncate is safe.

## Evaluation (`query.mbt`, `rank.mbt`)

Every posting list is doc-sorted, so a query's result is carried as two
parallel ascending arrays (`DocScores`) rather than a `doc -> score` map:

- `Term` reads its posting list once, scoring in place (`bm25_context` holds
  the per-(field, term) constants and a dense field-length array).
- `And` / `Or` / `Not` are merge joins over the arrays; `MatchAll` /
  `MatchField` produce ascending doc ranges with score 0.
- Ranking is a bounded top-K walk (`collect_hits`): a candidate is turned
  into a `Hit` (id lookup included) only when it beats the current worst of
  the top set, so a saturated query pays for ten string lookups, not twenty
  thousand.

The map-based evaluator is kept as a thin wrapper (`eval`) for `explain`,
which needs random access by doc number.

## Facets (`facet.mbt`)

Facets are exact-match keyword bags attached to an existing document (`set_facets`), stored per internal doc number and serialized in MSK3. `search_faceted` evaluates the query, filters by facet values (OR within a field, AND across fields), aggregates value counts over the *filtered* result set, and paginates with offset/limit. Facet values are not analyzed — `zh`/`en` stay exact strings, unlike text fields.

## BK-tree (`bktree.mbt`)

A metric tree over the vocabulary: each node stores a term; children are keyed by Levenshtein distance to the parent. A range query visits only children whose edge distance lies in `[d-bound, d+bound]`. Built lazily once per index (`bk_tree`), cached, invalidated on `add`. On a 23.8k-term vocabulary it beats the linear scan by 13–1780× for typical typos.

## Ranking control & explanation (`explain.mbt`)

- `SortOrder` selects score/id ordering; `search_after` pages by `(score, id)` cursor, which is stable across concurrent writes unlike offset pagination.
- `explain(query, id)` mirrors the evaluator: a phrase contributes its first term (phrase frequency folded in), a prefix expands to matching dictionary terms, `Not`'s right branch contributes nothing. df/idf are computed once per (field, term), and the document's posting is found by binary search since postings are doc-sorted.

## Performance notes

Three O(n²)-class issues were found by stress benchmarking and fixed:
1. **df inside the posting loop** — BM25 constants are precomputed per (field, term) in `Bm25Context`; posting scoring is O(1).
2. **Full sort with string tie-breaks** — `search(limit)` uses bounded top-K selection keyed on `(score, lexical id)`.
3. **Re-sorting the vocabulary per prefix query** — `terms_of` caches the lexicographically sorted list until the next `add`; prefix evaluation binary-searches it. Note that MoonBit's `String::compare` is *shortlex* (length first), so dictionary order requires `lexical_compare`.

## Browser exports (`web/`)

`pkgtype(kind: "foreign_library")` + `#export_name` exposes `ms_init / ms_add / ms_delete / ms_get / ms_search / ms_search_faceted / ms_set_facets / ms_explain / ms_highlight / ms_snippet / ms_suggest / ms_fuzzy / ms_term_stats / ms_snapshot_size / ms_save / ms_load / ms_count / ms_terms`. Only stable-ABI types cross the boundary (String, Int); search results and term stats are JSON strings; highlighting returns engine-escaped HTML. With `use-js-builtin-string`, MoonBit strings are JS strings — zero-copy. The host instantiates with `{ builtins: ["js-string"], importedStringConstants: "_" }`.

## Testing strategy

- Unit tests per module; blackbox tests exercise the public API; one whitebox drift-guard for the offset analyzer.
- Golden query tests pin result ids and ordering.
- Snapshot tests: roundtrip equality (ids + exact scores), determinism, bit-flip/truncation/bad-magic/bad-version detection, MSK1 backward compatibility.
- Store/WAL tests: real filesystem roundtrips, corrupt-file rejection, torn-tail recovery, checkpoint idempotence, no temp-file leakage.
- Segment tests: freeze threshold, cross-segment search/delete, latest-version-wins, merge preserves results.
- Quickcheck properties: snapshot roundtrip, varint codec, contiguous token positions, delete exclusion.
- Benchmarks (`bench_test.mbt`): 1000-doc synthetic corpus, index/term/phrase/snapshot.
- Browser: headless Chromium smoke tests (search, server-side marks, suggestion click, HTML escaping, benchmark panel).