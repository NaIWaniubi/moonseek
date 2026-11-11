# Changelog

## 0.9.0 (2026-11-12)

`sort` was documented in `docs/api.md` from the first release and **never wired
into the service**. A client that sent `sort=num:year&order=desc` got a
score-ordered response and no indication that its request had been ignored —
the worst of the three possible outcomes, because the contract said otherwise.

### Added

* `GET/POST /search` takes `sort=score|id|num:<field>` and `order=asc|desc`. The
  response echoes the order actually applied as `sort`/`order`, and a numeric
  sort also reports each hit's `sort_key`, so a client can check the order it got
  instead of trusting it.
* **An unrecognized sort is a `400`**, not a silent fall back to score order.
* `SortOrder` gains `NumAsc(String)` / `NumDesc(String)`; `compare_numeric` is
  public so the service, a shard and a client can all order identically. (Adding
  enum variants is why this is 0.9.0 and not 0.8.1: an exhaustive `match` on
  `SortOrder` stops compiling, which is the point.)
* Documents with no value for the sort field sort **last in both directions** —
  a missing value is not a small number, and treating it as zero would file
  every undated document between the oldest and the newest.

### Cross-shard

A coordinator now gets its exact global order for all three sort kinds. Each
shard is asked for its top `pool` **under the requested order** (a shard that
returned score-candidates while the query sorted by a field would hand the
coordinator a pool without the global top), and the shards ship the numeric key,
because the coordinator never sees the documents. The shard protocol's `search`
reply is now `[id, score, key]`; the two-element form is still accepted, so
adjacent versions can talk.

Measured: three queries × six orders (score/id/numeric × asc/desc) give
**18/18 identical hit lists** against a single node. A sort by id or by a numeric
field is exact in the default mode because it never reads a score; a score sort
is exact only under `dfs=true`, which is the difference the cluster document has
measured since 0.7.0.

### Fixed

* The library's `search_sorted` gained the two new orders, and the service's
  single-node path now sorts the **whole match set before paginating**. Sorting
  only the returned page would order ten score-ranked hits by the field, which is
  a different answer from the field-ordered page.

### Tests

322 native (up from 314), 275 wasm-gc / 275 js. New: four library tests for
numeric ordering (including the value-less and tie-break cases), five wire-level
tests for parsing and the merge comparator, and claim 6 in `tools/test-cluster.sh`.

## 0.8.0 (2026-11-12)

The distributed layer finished: it now grows without rewriting the corpus, takes
writes, replicates them, and answers facets and aggregations over the whole corpus
instead of returning them empty. Five bugs came out of building it, four of which
had been invisible since 0.7.0.

### Consistent hashing, and the three hashes that were wrong

Placement was `hash(id) % shards`, which renumbers every key when the shard count
changes. A hash ring with 128 virtual nodes per shard is now the default:
**adding a fourth shard moves 24.2% of 3,000 real documents instead of 74.9%**
(the ideal is 25%), and the ids land within 5% of even (969/1024/1007).

Getting there exposed three silent bugs in the hash itself:

* The JavaScript splitter computed `hash * 16777619` as a double. The product of
  two 32-bit values reaches 7.2e16, past `Number.MAX_SAFE_INTEGER`, so it rounded
  — it was never FNV-1a. Invisible because placement was never exercised.
* The MoonBit hash ran over UTF-16 code units while the splitter hashed UTF-8
  bytes. Those agree for ASCII, which every generated id was, and disagree for
  Chinese ones.
* FNV-1a is linear in the input bytes, so sequential ids sit in an arithmetic
  progression and a ring built from such keys measured **29% / 21% / 50%** behind
  three shards. MurmurHash3's `fmix32` finalizer brings it to 36% / 28% / 36%.

New: `build_ring`, `HashRing::owner`, `rebalance_plan`, `hash_key`, `parse_shard_mode`,
`--shard-mode`, `--vnodes`, and the endpoints `GET /_ring`, `GET /_placement?id=…`,
`GET /_plan?shards=N`. A golden test pins the hash to the JavaScript reference for
eight ids including two Chinese ones, and the e2e test checks the coordinator's
placement against the offline splitter document by document.

### Writes: the coordinator accepts them, and replicates

Before this the coordinator could not be written to at all — `POST /index` applied
the document to the coordinator's own empty index. Writes are now routed to the
group that owns the id and sent to **every member of that group**, in parallel, and
`POST /index/bulk` is grouped by owning shard so a shard receives only the
documents it owns.

`ok` in a write reply means *every* member applied it; a write acknowledged by one
member of three is reported as not-ok with the addresses that missed it.

Measured end-to-end: 3,000 documents written through the coordinator, **6 of 6
members acknowledged**, primaries and replicas holding identical shares; killing a
primary leaves total, ranking and shard accounting byte-identical.

### Distributed facets and aggregations

A coordinator now answers `facets` and `aggs` over the whole corpus. Terms sum per
value and cap **after** merging (a value ranked `size+1` in one shard can be in the
global top `size`); stats recombine counts and sums rather than averaging averages
(measured: 16.0 vs 28.7); histograms order by bucket index, not label text;
percentiles **ship raw values**, because the median of a union is not the average
of the medians (measured: 6.5 vs 11.0). Two engine functions became public for
this: `Index::agg_values` and `percentiles_of`.

`tools/check-distributed-aggs.py` compares a coordinator against a single node with
stated tolerances, and the cluster test runs it plain, filtered and over an
empty result set.

### Fixed

* **The coordinator ignored filters for ranking and total.** Found by the
  aggregation-equality test, which was not looking for it: filters reached the
  aggregation path but never the search request, so a filtered query returned 2376
  where a single node returned 1190 and ranked excluded documents.
* `stat_key` was deleted by a bad edit and restored; `cluster.mbt` had a raw NUL
  byte inside a byte literal, which broke text tooling.
* The cluster e2e test's post-failure total check used a hard-coded corpus
  threshold; it now compares against the pre-kill total.

### Added

* `tools/test-replication.sh` and a fourth CI job for the replication claim.
* Nine unit tests for the merge rules, each pinning a rule that produces a
  plausible number when it is wrong. 314 tests.
* `docs/api.md` documents the three new endpoints and the coordinator's write
  semantics; `docs/cluster.md` is rewritten around the ring, replication and the
  merges, with fresh measurements.

### Known

`moon check --target wasm-gc|js` reports 16 deprecation warnings in `web/api.mbt`
(`Json::as_array`/`as_string` are deprecated in favour of `is` patterns) and two
unused-import hints in the root `moon.pkg` for non-native targets. They predate
this release and are cosmetic; native is warning-free under `--deny-warn`. CI does
not deny warnings.

## 0.7.1 (2026-11-11)

One fix, found by the new 200k-document benchmark: **tombstones made every query
O(N)**. Deleting 10% of a 200,000-document corpus took a selective-term query
from 0.021 ms to 101 ms, because the live-document count re-scanned a field's
length table on every call and `bm25_context` calls it once per (field, term) per
query. The table already holds live documents only, so the scan was redundant as
well as quadratic. Now O(1); post-delete latency matches the clean case
(0.015 ms vs 0.027 ms). See `fixes_wbtest.mbt` for the regression test and
`docs/benchmark.md` for the 200k table.

## 0.7.0 (2026-11-11)

From an embedded library to a search platform: a network service, a distributed
mode, vector retrieval, and the aggregations a search UI needs.

### Added — moonseek-server: a real search service
`server/main.mbt` implements the contract in `docs/api.md`, frozen before the
implementation. Endpoints: `GET/POST /search` (filters, facets, aggregations,
highlighting, snippets, `explain`, vector `knn` + fusion), `POST /index`,
`POST /index/bulk` (newline-delimited JSON), `DELETE /index`, `GET /_stats`,
`GET /_healthz`, `GET /suggest`, `GET /terms`, `GET /explain`, `GET /_dfs`, and
static console assets with a path-traversal guard. Errors share one shape
(`{"error","code"}`) so a client never has to guess.

The service is a thin layer: everything that decides a result happens in the
library, so the two cannot drift apart.

### Added — distributed mode
One binary runs as a single node, a shard, or a coordinator
(`--shards`, `--shard-port`, `--pool`). Shards answer a small length-prefixed
JSON protocol over TCP; the coordinator owns no index, fans queries out to every
shard in parallel, merges per-shard top-k, and reports shard health.

Two scoring modes, both measured (`docs/cluster.md`):

| mode | round trips | ranking on 3 shards vs one node |
|---|---|---|
| local statistics (default) | 1 | 0/8 queries identical, score deltas to 0.82 |
| `?dfs=true` | 2 | **8/8 identical, max score difference 0** |

Globally consistent scoring installs corpus-wide `df`/`avgdl`/`N` on each shard
for one query (`Index::set_external_stats`). Prefix queries are refused with an
explicit note rather than mixed into a ranking they cannot support.

Measured steady state (30 queries × 8 shapes): single node p50 4.7 ms; 3 shards
local p50 6.7 ms; 3 shards `dfs` p50 6.9 ms.

Failover: a replicated group (`primary|replica`) survived its primary being
killed with the result unchanged (same total, `ok: 3, failed: 0`); an
unreplicated shard's death produced a partial answer with `ok: 2, failed: 1` and
the dead address named, while the coordinator kept serving.

### Added — vector retrieval (HNSW) and hybrid search
Pure-MoonBit HNSW: deterministic level assignment from a seed, greedy descent
plus a bounded beam, and neighbour pruning by distance. Measured recall against
brute force on random 32- and 64-dimensional data: ef=8 → 0.90, ef=32 → 0.996,
ef=64 → 0.999 (1,000 points); ef=256 → 1.0 (5,000 points).

`Index::hybrid_search` fuses BM25 and kNN with reciprocal rank fusion (default)
or a normalized weighted blend, reporting each hit's rank in both rankings.

Three real bugs were found and fixed while making this honest:

* **Pruning by insertion order split the graph.** Keeping the first `M` edges
  meant a full node never accepted a newcomer, so nodes inserted late got no
  inbound edges and layer-0 search reached 46 of 1,000 nodes — recall@10 was
  0.016 at every beam width. Pruning by distance fixed it.
* **The frontier cursor skipped better candidates** that were inserted *before*
  it during expansion, silently costing recall (0.999 → 0.982).
* **Distance computation probed a hash map per candidate and copied a vector per
  neighbour comparison**, making construction 74 s for 5,000×64. A flat point
  buffer with a stride, plus a doc-to-doc distance that allocates nothing,
  brought it to 31 s; a generation-stamped visited array replaced one hash map
  per beam-search call.

Graph construction on random uniform high-dimensional data is expensive because
distance gaps are small; real embeddings have far lower intrinsic dimension. The
31 s figure is for the adversarial case, and is documented rather than hidden.

### Added — numeric document values and aggregations
`set_num` attaches numbers to documents (the numeric counterpart of facets):
not analyzed, not scored, but filterable and aggregatable. `aggregate` runs
`TermsAgg`, `StatsAgg`, `HistogramAgg` and `PercentilesAgg` over exactly the
result set the caller returned hits from — aggregating over a different set is
how a search UI ends up lying about its own facets.

Buckets use a real floor division, so -0.5 and +0.5 land in different buckets
(truncation toward zero put them together). "No value" is a NaN sentinel tested
with `v == v`, not 0.0, because 0.0 is a legitimate value and treating absence
as zero corrupts every average.

### Fixed
* **Tombstones made every query O(N).** `field_live_count` re-scanned a field's
  length table whenever `deleted` was non-empty, and `bm25_context` calls it once
  per (field, term) per query. On 200,000 documents, deleting 10% took a
  selective-term query from **0.021 ms to 101 ms** — a 5000× regression from
  tombstones alone. The table holds live documents only (`delete_by_num` removes
  the entry and decrements `total_length`), so the scan was redundant as well as
  quadratic; the count is now O(1). After the fix, post-delete latency matches
  the clean case (0.015 ms vs 0.027 ms). Found by `bench/scale`, which is why
  that benchmark exists.
* **Every latency in the service was reported 1000× too small**: `@env.now()` is
  milliseconds and several call sites divided by 1000 again. `took_ms` was
  returning seconds.
* **The default highlight field was hardcoded to `body`**, so every hit on any
  other schema came back with an empty snippet. It now follows the schema's
  lowest-weighted field.
* **A shard's match count cost a second full ranking** (`search(limit=0)` builds
  and sorts every hit). New `Index::count` counts matches without materializing
  them; the cluster's per-query cost dropped from 92–272 ms to 43–96 ms.
* **The statistics round re-analyzed every document** to recount field lengths,
  costing ~45 ms per query. It now reads the index's own per-field totals in
  O(1).
* **The coordinator died with its shard**: `spawn` defaults to
  `allow_failure=false`, so a shard's failure cancelled the whole task group.
* **The stats request was not JSON** (`"term":"field"` inside an array), so every
  shard answered `bad json` while the coordinator reported success.

## 0.6.0 (2026-11-11)

This release is about evidence rather than speed: real data, measured retrieval
quality, and the one query feature the syntax was missing.

### Added — sloppy phrase queries (`"a b"~N`)
`Query::Phrase` carries a slop distance; the lexer parses a `~N` suffix on a
quoted phrase (and on `field:"..."~N`). Slop widens the gaps allowed between
neighbouring terms while keeping their order: `"database index"~3` matches
"database ... index" with up to three intervening tokens.

The matching algorithm is a **minimal-span walk**, not a per-start-position
lookahead. The naive version reports one occurrence once per starting position
that can reach it, inflating tf and therefore the BM25 score; `slop_test.mbt`
pins the correct count (a document with three occurrences and slop 1 scores
tf = 3, not 9). Slop 0 is bit-identical to the previous exact-phrase path, and
the tests assert both that property and monotonicity in N.

Measured cost on the 20k corpus: exact phrase 6.25 ms p50, `~3` slop 7.89 ms p50
— a binary search per term per candidate window.

### Added — real corpus, cross-target, in the browser
- `tools/registry-corpus.mjs` turns the mooncakes registry index into
  `demo/registry.json`: **3,698 packages / 22,837 versions**, with names,
  author keywords, descriptions, dependency edges and facet values.
- `tools/registry/main.mbt` builds that corpus into a `MSK3` snapshot with the
  **native** binary (11,081 terms, 1.37 MB, ~8,000–11,000 docs/s).
- The **wasm-gc** build loads those exact bytes. This exposed a real bug:
  `Bytes` has no stable JS ABI, so `ms_load`/`ms_save` never worked from
  JavaScript. New `ms_load_b64` / `ms_save_b64` (base64) are the working
  transport, and a CI job now proves native→wasm snapshot compatibility.
- New `ms_set_schema`, `ms_add_doc` (arbitrary fields), `ms_dump`,
  `ms_search_faceted_fields` (the demo had hardcoded `cat`/`lang` facet names,
  which silently returned no aggregations for the registry's `license`/`deps`/
  `year` fields).

### Added — retrieval-quality measurement
`tools/eval` computes **NDCG@10 / MRR@10 / Recall@20** over 17 queries and six
configurations, and writes `docs/quality.md`. Labels are **derived from corpus
structure** (author keywords, declared dependency edges, package-name tokens)
and the report says so in its first paragraph: these numbers are comparable
across configurations, not to BEIR or MS MARCO.

| configuration | NDCG@10 | MRR@10 | Recall@20 |
|---|---:|---:|---:|
| `bm25-weighted` (shipped) | **0.9045** | 1.0000 | 0.3376 |
| `no-length-norm` (b = 0) | 0.9142 | 1.0000 | 0.3323 |
| `bm25-uniform` | 0.8236 | 0.9314 | 0.2902 |
| `metadata-only` | 0.7185 | 0.7941 | 0.3227 |
| `desc-only` | 0.4771 | 0.5899 | 0.1421 |
| `title-only` (≈ substring search) | 0.4082 | 0.4706 | 0.0953 |

The honest reading: field weighting is worth 10% NDCG over uniform weights and
122% over name-only search; **length normalization is worth -1.1% here**, i.e.
within noise, and the report says that instead of claiming a win.

### Changed — the demo is a product, not a mock
`demo/index.html` rewritten. It searches the real registry (snapshot load
~200 ms, median query 0.20 ms, p90 0.2–0.3 ms), indexes files you drag in
(`.txt .md .json .csv .log .html`, with JSON flattened to its text), persists
the whole index to IndexedDB as one snapshot blob and reloads it without
re-parsing, and runs a live benchmark measuring latency percentiles plus a
latency-vs-index-size curve. The ablation table is shown next to the live
numbers.

### Changed — benchmarks that do not flatter themselves
- The stress harness now reports the **median of 4 build runs** (a single
  sample swung 20–30% and a lucky one had been published as 8,900 docs/s; the
  real figure is 6,400–7,800, and the withdrawal is documented in
  `docs/benchmark.md`).
- Query latency is **p50/p90 of 200 samples per shape** instead of one mean.
- Two stress cases were found to be timing terms that do not exist in the
  generated corpus (`w4999x`, `title:rust`) — i.e. an empty posting list. They
  now pick terms by actual `doc_freq` and print it.
- `docs/benchmark.md` rewritten end to end: the old version described the 0.4.x
  evaluator (score-map materialization, 3,000 docs/s, 13 ms saturated terms),
  none of which is true of the current build.

### Fixed
- `docs/benchmark.md` and the README claimed numbers from two architectures ago.

## 0.5.1 (2026-11-12)

### Changed
- **Index build 6,500 → 8,900 docs/s** on the 20k-doc stress corpus: `add`
  reuses a per-field term/position accumulator instead of allocating a map per
  document-field, and CJK bigrams are interned (one string per distinct pair,
  capped at 65,536 entries) instead of concatenated per occurrence.
- Subsequent query deltas: saturated term 2.5 → 2.0 ms, Chinese bigram
  3.0 → 2.3 ms, boolean 5.2 → 4.0 ms, prefix 2.4 → 2.2 ms, snapshot serialize
  0.71 → 0.60 s.
- Docs refreshed with the post-rewrite numbers (`docs/benchmark.md` gains a
  0.5.x revision table, `docs/architecture.md` documents the evaluator).

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