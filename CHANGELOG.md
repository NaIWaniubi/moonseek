# Changelog

## 0.3.0 (2026-11-05)

### Added
- **Faceted search** (`facet.mbt`): exact-match facet values per document, AND/OR filters, per-value aggregation counts, offset pagination. `search_faceted` returns `{hits, total, facets}`.
- **BK-tree** (`bktree.mbt`): metric-tree index over the vocabulary for sub-linear fuzzy lookup. `Index::bk_tree()` caches one tree per index (invalidated on add); 13–1780× faster than the linear scan on a 23.8k-term vocabulary.
- **Score explanation** (`explain.mbt`): `explain(query, id)` returns per-(field, term) tf/df/idf/norm/score contributions, matching the evaluator's semantics (phrase folds into its first term, prefix expands).
- **Sort orders and cursor pagination**: `search_sorted` (ScoreDesc/Asc, IdAsc/Desc), `search_after` for stable pages.
- **Snapshot MSK3**: facets persisted; MSK1/MSK2 images remain readable.
- **Demo v4**: facet chips with live counts, "clear filters", and an expandable "why this result" BM25 breakdown per hit.
- **`bench/stress`**: 20k-doc stress benchmark (indexing, 9 query shapes, fuzzy linear vs BK-tree, facets, snapshot, explain).

### Changed
- `terms_of` now sorts with `lexical_compare` (true dictionary order) and caches the result until the next `add`. **MoonBit's `String::compare` is shortlex**, which scatters prefix-sharing terms and breaks binary search — all id tie-breaks were aligned to lexical order too.
- `search` with a positive limit performs bounded top-K selection instead of a full sort.
- BM25 constants (idf/avgdl/df) are computed once per (field, term) via `Bm25Context`; scoring a posting is O(1).
- Prefix queries binary-search the sorted term list, then walk matches.

### Fixed
- **O(df²) term queries**: df was recomputed inside the posting loop (a 20k-doc saturated term took ~140 ms; now ~13 ms with hot-path context reuse).
- **O(df²) explain**: 4.1 s → milliseconds (binary search + one context per term).
- WAL append used the default `CreateOrTruncate`, wiping the log on every append; now `OpenOrCreate` (found by the WAL tests, regression-covered).
- Facet UI: a 0-result filtered search no longer hides the active chip, so filters can always be cleared.
- `explain_terms` took `self` as its first parameter, which MoonBit treats as a method, making it invisible to plain calls.

## 0.2.0 (2026-11-04)

### Added
- **Stored fields**: original document texts are kept in the index; `get_document` / `get_field` retrieve them, and they survive snapshot roundtrips (format bumped to MSK2; MSK1 images still load).
- **Fuzzy search**: Levenshtein and Damerau-Levenshtein edit distance, `fuzzy_terms` / `fuzzy_search` with length pruning and distance cap.
- **Did-you-mean**: `suggest` proposes frequency-weighted spelling corrections for misspelled query terms.
- **Server-side highlighting**: `highlight` / `highlight_spans` / `snippet` with HTML escaping, CJK bigram span mapping, overlap merging, and densest-window snippet extraction.
- **Segmented index**: `SegmentedIndex` with immutable segments, configurable freeze threshold, tiered merge policy, and cross-segment search with latest-version-wins semantics.
- **Write-ahead log**: `wal_encode` / `wal_decode` with per-entry CRC and torn-tail recovery; native durable add + checkpoint + crash-safe open.
- **Property tests**: quickcheck properties for snapshot roundtrip, varint codec, token positions, and delete exclusion.
- **Examples**: `examples/basic.mbt` (queries + stored fields) and `examples/persistence` (atomic save/load).
- **Demo v2**: 60-document bilingual corpus, live benchmark panel, index inspector with term-frequency bars, query syntax reference.

### Changed
- Phrase evaluation now builds per-term doc maps: O(positions) instead of O(docs × positions) per candidate.
- Snapshot deleted-doc list is sorted for deterministic output.
- CI runs debug + release tests on the full OS × target matrix, plus a benchmark job.

### Fixed
- Zero compiler warnings on native (explicit trait extends, modern operators, qualified test imports).

## 0.1.0 (2026-11-04)

Initial release: inverted index, BM25 ranking, CJK bigram tokenization, boolean/phrase/prefix/field queries, CRC-checksummed snapshots, crash-safe native store, CLI, browser WASM demo.