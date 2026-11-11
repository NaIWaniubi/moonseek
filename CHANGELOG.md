# Changelog

## 0.5.0 (2026-11-12)

### Changed — query evaluation rewritten (the biggest architectural gap)
`eval` no longer materializes a `doc -> score` HashMap; it returns ascending
(doc, score) arrays and every operator is a linear merge (`rank.mbt`).
`And`/`Or`/`Not` are set merges, `collect_hits` runs a bounded top-K walk that
only builds a `Hit` once a candidate enters the top set, and BM25 scoring reads
field lengths from a cached dense array instead of a hash probe per posting.
Deleted-doc checks are hoisted out of the hot loops when there are no tombstones.

Measured on the 20k-doc / 8.5 MB / 23.8k-term stress corpus (release, per query):

| Query | 0.4.0 | 0.5.0 | |
|---|---|---|---|
| Saturated term (df ≈ all docs) | 13.0 ms | **2.5 ms** | 5.3× |
| Anchor term (df ≈ 2k) | 12.0 ms | **2.3 ms** | 5.1× |
| Boolean `A AND B` | 22.2 ms | **5.2 ms** | 4.2× |
| Phrase | 18.5 ms | **7.0 ms** | 2.6× |
| Prefix | 16.6 ms | **2.4 ms** | 6.9× |
| Chinese bigram | 13.1 ms | **3.0 ms** | 4.4× |
| Facet filter + aggregation | 21.3 ms | **11.8 ms** | 1.8× |
| Explain | 3.3 ms | **2.3 ms** | 1.4× |

### Added
- **Live demo on GitHub Pages**: <https://naiwaniubi.github.io/moonseek/> — the
  WasmGC build served statically so the engine can be tried without a local
  server (release wasm, 204 KB).
- **`diff_test.mbt`**: differential and invariant tests. A reference BM25
  recomputed from public primitives (`postings_of`/`doc_freq`/`schema`) matches
  engine scores to 1e-9; boolean operators are checked against set algebra on
  the operand result sets; `limit=k` is asserted to be the exact prefix of
  `limit=0`; insertion order and deletion are asserted not to change relevance.
- README: live-demo link, badges, demo screenshot, Mermaid pipeline diagram.

### Fixed
- Test-only: the set-algebra test aliased its operands (`let union = sa`), so
  the union push mutated the array the later assertions compared against.

## 0.4.0 (2026-11-11)

### Added
- **`ByteWriter`** (`bytewriter.mbt`): preallocated `FixedArray[Byte]` buffer with amortized growth and `blit_from_bytes`. Snapshot serialization on the 17.6 MB stress image: 2.4 s → ~1.0 s; deserialize 1.7 s → ~0.8 s (single `blit` instead of per-byte HashMap-of-Array pushes).
- **`docs/benchmark.md`**: performance whitepaper — environment, reproduction commands, full stress/`moon bench`/WasmGC tables, and an honest limitations section (single-threaded scheduler, per-query score map, no SIMD).
- **`docs/comparison.md`**: 17-dimension feature matrix vs tantivy / Lucene / bleve with honest gaps and positioning.
- **`examples/advanced`**: one runnable program exercising facets, BK-tree fuzzy, suggest, explain, sort orders, cursor pagination, highlight and snippet.
- **Stress harness hardening**: explain is now measured 100× *before* the snapshot roundtrip — the earlier 1.9 s reading was GC-pause pollution from the 17 MB allocation immediately prior, not algorithmic cost (real: ~3.3 ms).

### Changed
- `Bm25Context` carries `df` so explain no longer recomputes document frequency per term.
- `doc_freq` fast path: when the index has no tombstones, df is just the posting-list length (no per-element `deleted` probes).
- Stress harness prints a revision table comparing Array-push vs ByteWriter serialization.

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