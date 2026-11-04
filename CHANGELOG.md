# Changelog

## 0.2.0 (unreleased)

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