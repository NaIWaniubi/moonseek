# moonseek Performance Whitepaper

Every number here was produced by a harness in this repository, and each row names the harness.
Nothing is extrapolated: shapes that were not measured are listed as missing in
[Limitations](#limitations-and-what-is-not-measured), and where a measurement was too noisy to
quote to three digits, it is quoted as a range.

A note on numbers you may have seen elsewhere: an earlier revision of this document quoted
3,000 docs/s, 13 ms saturated-term queries and a per-query `doc -> score` map. Those described the
0.4.x evaluator. The map is gone (0.5.x evaluates over ascending arrays), and the figures below are
from the current build. Where a measurement changed *for the worse*, it is reported as such: the
build-throughput figure is lower than a previously published single-sample number, and
[the ablation study](quality.md) shows BM25 length normalization to be worth about +1% NDCG on this
corpus rather than a clear win. Both are in here, not hidden.

## Test environment

| Item | Value |
|---|---|
| CPU | AMD Ryzen 7 7435H (8 cores / 16 threads) |
| RAM | 16 GB DDR5-4800 |
| OS | Windows 11 (10.0.22631), NTFS |
| Toolchain | `moon 0.1.20261023`, `moonc v0.10.17`, `moonbitlang/core 0.10.17` |
| Target | `native`, single-threaded |
| Build | `--release` for every number in this document |
| Corpus | 20,000 synthetic documents, 8.57 MB raw text, 23,782 distinct terms |

"Single-threaded" is precise: the engine spawns no threads and has no parallel segment search. The
only concurrency in the stack is `moonbitlang/async`'s cooperative scheduler, used for file I/O.

## Harnesses

| Harness | Command | What it produces |
|---|---|---|
| Stress | `moon run bench/stress --target native --release` | 20k-doc build (median of 4), 10 query shapes (p50/p90 of 200 samples), fuzzy linear vs BK-tree, facet filter+aggregate, `explain`, 17.6 MB snapshot roundtrip |
| Micro | `moon bench --release` | 1,000-doc corpus through `@bench.T`: build, term, phrase, snapshot roundtrip |
| Quality | `moon run tools/eval --target native --release -- demo/registry.json docs/quality.md` | NDCG@10 / MRR@10 / Recall@20 over 3,698 real packages and 6 ablation configurations |
| Registry build | `moon run tools/registry --target native --release -- demo/registry.json demo/data/registry.msk` | The snapshot the browser demo loads, plus its build rate |
| Browser | `demo/index.html` (WasmGC) | Snapshot load, query percentiles, snapshot export/import, latency-vs-scale curve, all in-page |
| Correctness | `moon test` | 259 tests native / 242 wasm-gc — run this before trusting any number |

The stress corpus is generated in-process by `bench/stress/main.mbt` from a seeded xorshift RNG, a
5,000-word Zipf vocabulary and 30 real English/Chinese anchor words. The generator is integer-only,
so the corpus is byte-reproducible.

## Headline numbers

### Index construction

Measured as the **median of 4 timed runs** (a fifth is discarded as warm-up), because a single run
on a desktop machine swings 20–30% with background load.

| Metric | Value | Source |
|---|---|---|
| Documents | 20,000 | `bench/stress/main.mbt` |
| Raw text | 8.57 MB | harness printout |
| Distinct terms | 23,782 | `idx.term_count()` |
| Build time (median) | **2.73 s** (range 2.30–3.43 s) | `bench/stress/main.mbt` |
| Throughput (median) | **7,320 docs/s** | `n_docs / build_us` |
| Snapshot | 17.6 MB | `image.length()` |

The build path per document is: analyze → emit `(term, position)` pairs → append postings → update
per-field length stats → store original field text. No merge, no flush, no I/O.

An earlier revision quoted 8,900 docs/s. Re-measuring with repeats and a median put the same build
at 6,400–7,800 docs/s depending on machine state; the single-sample 8,900 was a lucky run and has
been withdrawn. The 0.5.x optimizations that produced it (per-field slot accumulator, interned CJK
bigrams) are still in the code — only the quoted number changed.

### Query latency

Ten shapes against the 20k-doc index, `limit=10`. Each shape is warmed up, then timed over **200
samples**; the table reports p50 and p90. A mean over one long loop was what this document used to
quote, and it hides the tail a user notices.

| Query shape | df of the queried terms | p50 | p90 |
|---|---:|---:|---:|
| Selective term | 285 | **0.06 ms** | 0.08 ms |
| Mid-frequency term | 230 | **0.05 ms** | 0.06 ms |
| Anchor term | 4,114 | **2.21 ms** | 2.40 ms |
| Saturated term | 4,021 | **2.14 ms** | 2.41 ms |
| Chinese bigram | 4,113 | **2.19 ms** | 2.50 ms |
| Boolean (`search AND engine`) | two saturated | **4.50 ms** | 5.31 ms |
| Exact phrase (`"database index"`) | positional | **6.25 ms** | 7.29 ms |
| Sloppy phrase (`"database index"~3`) | positional + span walk | **7.89 ms** | 8.81 ms |
| Field-scoped (`title:moonbit`) | 732 | **0.13 ms** | 0.15 ms |
| Prefix (`seg*`) | expansion | **2.13 ms** | 2.33 ms |

Two things to read here. First, the spread between a selective term and a saturated one is now
about 40×, not the ~650× of the map-based evaluator: the merge-based evaluator touches each posting
once and selects top-K by bounded insertion rather than sorting the whole result set. Second, a
sloppy phrase costs about 1.6 ms more than an exact one on this corpus — the minimal-span walk adds
a binary search per term per candidate window, which is the expected price for allowing gaps.

The df column matters: a query shape is only meaningful if the term exists. Earlier revisions of
this harness measured `w4999x` and `title:rust`, neither of which occurs in the generated corpus,
so those two rows were timing an empty posting list. They now pick terms by their actual document
frequency and print it.

### Block-max WAND: skipping the postings that cannot win

A bounded query that is a single term — or a conjunction of terms — does not
have to score every matching posting.

**Single term.** The doc-sorted posting list is walked in blocks of 16 and, once
the top-`k` set is full, a block is skipped when the highest score any posting in
it can reach is strictly below the current k-th best. The bound is the block's
own maximum (the `tf / (tf + k1·norm(dl))` maximum over its postings, times the
block's constant factors), computed once per term and cached, and evaluated
lazily — only for blocks the walk actually visits, not for all of them.

**Conjunction** (`a b`, `a AND b`). The shortest term's list drives the walk:
only its documents can match, so the other terms are asked about those documents
instead of being enumerated — a saturated term is never fully walked. A driver
block is skipped when the *sum* of the terms' block maxima cannot reach the
threshold. Scores are summed in the query's term order, which is the order the
exact evaluator's nested intersections sum in.

In both cases the skip test is **strict**, so a document that only ties with the
k-th best is still scored and can still win the id tiebreak — the result is
bit-for-bit the full scan, not merely close. Six engine tests assert that
equality (field-scoped and across fields, with deletions, including a corpus
with one huge tie group sitting on the cut) and assert that the skipping fires,
so it cannot silently regress to a no-op. A bounds bug this caught: the block
bound was computed from factored terms and could land one ulp *below* a
posting's actual score, which skipped a tie; the shipped bound is inflated by
one part in 1e12, which can only make a block less likely to be skipped.

20,000 documents, `limit=10`, p50 of 200 samples:

| Query | scored | skipped | p50 block-max | p50 exact | Speedup |
|---|---:|---:|---:|---:|---:|
| `moonbit` (df 4,114) | 1,373 | 3,473 (72%) | **0.65–1.06 ms** | 2.50–2.94 ms | 2.8–3.8× |
| `search` (df 4,021) | 1,221 | 3,457 (74%) | **0.47–0.83 ms** | 2.30–2.61 ms | 3.1–4.4× |
| `搜索` (df 4,113) | 1,221 | 3,565 (74%) | **0.40–1.00 ms** | 2.31–2.83 ms | 2.8–5.7× |
| `search AND engine` | 710 | 1,817 (72%) | **2.85–3.51 ms** | 4.27–5.60 ms | 1.5–1.6× |
| `moonbit AND search` | 719 | 1,675 (70%) | **2.43–2.84 ms** | 4.58–5.55 ms | 1.9× |
| `search AND engine AND index` | 256 | 853 (77%) | **4.07–4.25 ms** | 7.24–9.63 ms | 1.7–2.3× |

Ranges are across repeated runs on the same machine; the harness is
single-threaded on a shared machine, so the ratio is steadier than the absolute
figures.

**What is not done: there is no SIMD scoring loop.** MoonBit's core library
exposes only an experimental, hidden `v128_load` and no arithmetic intrinsics, so
a hand-vectorised BM25 loop would need FFI or a third-party dependency — both
against this project's "pure MoonBit, two dependencies" design. What was done
instead, and measured above: the per-candidate `Hit` allocation was removed (a
candidate gets a `Hit` only when it can enter the top set), the block bound is
computed lazily, and the single-field case scores without an intermediate
buffer. Those, not arithmetic width, were where the remaining time went.

Skip rates are corpus-dependent: high when a term's per-document frequency is
skewed, low when it is uniform. Multi-term **disjunctions** (`a OR b`) still use
the exact union; extending the walk to them is the next step.


### Fuzzy lookup: linear scan vs BK-tree

23,782 terms, `max_distance=2`, Damerau-Levenshtein (adjacent transposition = 1 edit). Five real
typos, one run each side:

| Query | Linear scan | BK-tree | Speedup |
|---|---:|---:|---:|
| `serch` | 46.3 ms | 2.17 ms | 21× |
| `engin` | 44.0 ms | 1.96 ms | 22× |
| `moonbt` | 42.1 ms | 0.16 ms | 261× |
| `databse` | 36.7 ms | 0.07 ms | 491× |
| `wasmm` | 44.2 ms | 2.66 ms | 17× |

The speedup spread is the interesting part, not the average: the BK-tree prunes by edit distance,
so a typo whose neighbourhood is sparse (`databse`, `moonbt`) finishes in well under a millisecond
while one with many near neighbours in the vocabulary (`wasmm`, `serch`) explores a larger subtree.
The tree is built lazily once per index and cached until the next `add`; build cost is not included
per query.

### Faceted search and explanation

| Operation | Time | Source |
|---|---:|---|
| `set_facets` for 20,000 docs | 34 ms (one-time) | `bench/stress/main.mbt` |
| Query + 1 filter + 1 facet aggregation, 3,055 matches | **14.0 ms** | `bench/stress/main.mbt` |
| `explain`, 100 calls | **2.18 ms/query** | `bench/stress/main.mbt` |

The faceted shape is `search_faceted("search", {filters: [{field: "lang", values: ["en"]}],
facet_fields: ["topic"]})`: evaluate the term, filter by one facet field (OR within, AND across),
count remaining values, then paginate. The 14 ms covers all four phases.

`explain` at 2.18 ms/query is about the same as the 2.14 ms the same term query costs — explaining
a hit re-derives the term's BM25 context through a binary search over the posting list rather than
reusing the evaluator's arrays. It is a diagnostic call, so that is a reasonable trade, but it is
not free and this document says so.

### Snapshot persistence

| Operation | Size | Time |
|---|---:|---:|
| `to_bytes()` | 17.6 MB | **0.68 s** |
| `from_bytes()` | 17.6 MB | **0.75 s** |

MSK3 is varint postings with delta-encoded positions, sorted terms, stored fields, facet values and
a CRC-32 over the payload. Both figures include CRC computation and exclude file I/O. Serialization
is now faster than deserialization: writing is a straight append through `ByteWriter`, while reading
must rebuild per-term hash maps.

### Large scale: 200,000 documents

`moon run bench/scale --target native --release -- --docs 200000` (median of 3
builds, p50/p90/p99 of 200 samples per shape). The corpus is generated
streaming — one document at a time, handed to `add`, then dropped — so the
harness does not hold a second copy of the text.

| metric | value |
|---|---|
| Documents / terms / raw text | 200,000 / 350,032 / 108 MB |
| Build (median of 3) | 21.7 s |
| Build throughput | **8,462 docs/s** |
| Saturated term (df 41,524) | p50 24.4 ms, p99 44.5 ms |
| Mid-frequency term (df 3,908) | p50 2.07 ms |
| Selective term (df 117) | p50 **0.021 ms** |
| Boolean AND (12,985 matches) | p50 45.6 ms |
| Exact / sloppy phrase | p50 84.8 / 121.3 ms |
| Prefix expansion (61 terms) | p50 3.0 ms |
| Snapshot | 202.7 MB, serialize 7.96 s, load 7.15 s |
| Estimated resident index | ~810 MB (raw text 108 MB + 14.6M postings + 14.8M positions) |

**Peak RSS is not measured in-process**: `moonbitlang/core` exposes no memory
API, so the 810 MB figure is a model (see the caveat block below), not a reading.

Deleting 10% of the corpus used to make every query O(N) — a selective term went
from 0.021 ms to 101 ms, because the live-document count re-scanned the field
length table on every term. That is fixed in 0.7.0; post-delete latency now
matches the clean case (0.015 ms). The before/after is in `CHANGELOG.md`.

### Registry corpus: 3,698 real packages

This is the corpus the browser demo ships, built from the live mooncakes registry index.

| Metric | Value |
|---|---|
| Packages | **3,698** (22,837 published versions) |
| Fields indexed | title, keywords, desc, deps |
| Raw source | 1.5 MB JSON |
| Distinct terms | 11,081 |
| Native build time | **0.34–0.46 s** (8,000–10,700 docs/s) |
| Snapshot | 1.37 MB (1.82 MB as base64) |
| Snapshot load in browser | **190–210 ms** |

Indexing real, messy, third-party metadata is the honest version of "does this work on data you did
not write". 393 of the 3,698 packages have no description at all, the descriptions are in several
languages, and the keyword lists are author-chosen — so this corpus exercises exactly the cases a
synthetic Zipf vocabulary does not.

### Browser (WasmGC)

The same 1.37 MB snapshot, loaded into `web/api.mbt` compiled to wasm-gc (**206 KB** binary), in
Chromium on the machine above:

| Metric | Value |
|---|---|
| Binary | 206 KB |
| Snapshot load (`ms_load_b64`) | 190–210 ms |
| Median query, 12-query mix × 5 rounds | **0.20 ms** |
| Query p50 / p90 / p99, 15-query mix × 20 rounds | 0.10 / 0.20–0.30 / 2.1–3.5 ms |
| Snapshot export (`ms_save_b64`) | 200–315 ms |
| Snapshot re-import | 80–140 ms |

Measured with `performance.now()` in `demo/index.html`. The base64 hop costs: the same snapshot
takes 80–140 ms to re-import from an already-decoded base64 string versus 190–210 ms for the first
load (which also includes fetching bytes and building the string). `Bytes` has no stable JS ABI, so
base64 is the transport — a real cost, and the reason `ms_load_b64` exists next to `ms_load`.

### Micro benchmark (`moon bench --release`)

1,000 synthetic documents, ~80 tokens each, `@bench.T`:

| Operation | Time (mean ± σ) |
|---|---:|
| Index 1,000 docs (with stored fields) | **85.8 ms ± 6.2** |
| Term query, top-10 | **262 µs ± 12** |
| Phrase query, top-10 | **1.01 ms ± 0.24** |
| Snapshot save + load | **45.3 ms ± 2.7** |

Per-document build cost here is 86 µs versus the stress harness's 137 µs/doc. The stress corpus has
more distinct terms per document (a 5,000-word Zipf vocabulary spread over 40–100 tokens), which is
why its per-document cost is higher. Both are reported; neither is presented as "the" build speed.

## Methodology

### Reproducing every number

```bash
# Correctness first — never benchmark a broken build
moon test                                      # 259 tests

# Quality (needs the registry dump; see tools/registry-corpus.mjs)
moon run tools/eval --target native --release -- demo/registry.json docs/quality.md

# Stress (20k docs, all shapes, medians and percentiles)
moon run bench/stress --target native --release

# Micro
moon bench --release

# Browser: rebuild the wasm, serve, click 运行基准测试
moon build --target wasm-gc --release
cp _build/wasm-gc/release/build/web/web.wasm demo/web.wasm
cd demo && python -m http.server 8931
```

Timing uses `@bench.monotonic_clock_start()` / `monotonic_clock_end()` (microseconds) in the stress
harness and `performance.now()` in the browser.

### What the numbers include

- **Build** includes tokenization, posting append, statistics update and storing original text.
  It excludes snapshot serialization and disk I/O.
- **Query latency** includes parsing, evaluation, scoring and building the `Hit[]`, with a
  `sink += hits.length()` accumulator so the work is not optimizable away.
- **Snapshot timings** include CRC-32 over the full payload; they exclude the file write.
- **Fuzzy timings** include candidate filtering and distance computation; they exclude the one-time
  BK-tree build.
- **Browser timings** include the JS↔wasm boundary crossing, since that is what a user experiences.

### Variance

Repeated measurement on this machine gives ±10–15% run-to-run for build and ±20–30% for the
sub-0.1 ms query cases (Windows timer granularity plus scheduler jitter). Sub-100 µs figures should
be read as "well under a tenth of a millisecond", not as three significant digits. The stress
harness prints its own min/max range so a rerun is directly comparable.

## Limitations and what is not measured

1. **Single-threaded by design.** No worker pool, no parallel segment search, no concurrent
   indexing. Throughput scales with one core; the machine's other cores are unused.
2. **No SIMD.** MoonBit core exposes only an experimental, hidden `v128_load`
   and no arithmetic intrinsics, so the scoring loop is scalar. The scalar work
   it leaves — per-candidate `Hit` allocation, eager block bounds, an
   intermediate buffer per block — was removed and measured instead; see
   *Block-max WAND* above.
3. **`explain` re-derives scoring state.** It costs about as much as the query it explains
   (2.18 ms vs 2.14 ms), because it binary-searches posting lists instead of reusing evaluator
   arrays. Fine for a diagnostic, not for a per-hit path.
4. **No incremental segment writes in the measured path.** `SegmentedIndex` exists and is tested,
   but the stress harness indexes into a single in-memory `Index`; merge cost under continuous
   writes is not benchmarked.
5. **No sharding.** "20,000 documents" is one process, one index.
6. **Cold-start and disk I/O excluded.** `save`/`load` on real filesystems depends on the page
   cache and is not part of the in-memory figures.
7. **Two corpora, both partial.** The stress corpus is generated (reproducible, but not a crawl).
   The registry corpus is real metadata, but short: the median description is 63 characters. Long
   documents with many fields are not represented here.
8. **The quality numbers are derived, not human-judged.** `docs/quality.md` explains exactly how the
   labels are computed from corpus structure. They are comparable across the configurations in that
   table and not comparable to published BEIR/MS MARCO scores.
9. **BM25 length normalization is not a clear win on this corpus.** The ablation shows `b = 0`
   scoring +1.1% NDCG@10, which is within noise for 17 queries. It is kept because short-metadata
   corpora are exactly where length normalization does least work, and the parameter is exposed.

## Where each number came from

| Number | File | Mechanism |
|---|---|---|
| 20k docs, 8.57 MB, 23,782 terms, 2.73 s median, 7,320 docs/s | `bench/stress/main.mbt` | 5 build runs, warm-up discarded, median of 4 |
| 10 query shapes p50/p90 | `bench/stress/main.mbt` | 10 warm-up calls, then 200 timed samples sorted per shape |
| Fuzzy 17–491× | `bench/stress/main.mbt` | `fuzzy_terms` vs `fuzzy_terms_fast`, one run each |
| 34 ms `set_facets`, 14.0 ms faceted query | `bench/stress/main.mbt` | `search_faceted` with one filter and one facet field |
| 2.18 ms explain | `bench/stress/main.mbt` | 100 `explain` calls timed together |
| 0.68 s / 0.75 s, 17.6 MB | `bench/stress/main.mbt` | `to_bytes` / `from_bytes` timed separately |
| 3,698 packages, 11,081 terms, 1.37 MB snapshot | `tools/registry/main.mbt` | registry dump -> `MSK3` |
| 190–210 ms load, 0.20 ms median query, 206 KB | `demo/index.html` | `performance.now()` around `ms_load_b64` / `ms_search` |
| 85.8 ms / 262 µs / 1.01 ms / 45.3 ms | `bench_test.mbt` | `@bench.T` per test |
| NDCG 0.408–0.914 | `tools/eval` | `docs/quality.md` |
| 259 / 242 tests | `moon test` | `Total tests: 259, passed: 259, failed: 0.` |

## Reading the numbers correctly

The intended takeaway is not "moonseek is fast in absolute terms" — a 20k-document corpus is small,
and tantivy or Lucene would beat these figures on the same hardware. The takeaway is the shape:

- **Selective queries are effectively free** (tens of microseconds) because the evaluator touches
  only the queried term's postings and top-K selection is bounded.
- **Saturated queries cost about as much as scanning the posting list**, which is the floor for any
  document-at-a-time engine without block-max pruning. That is the next optimization, and it is
  listed as unmeasured rather than assumed.
- **Costs are stable across shapes** within a factor of 40, not 650 — the property that makes a
  search box feel predictable.