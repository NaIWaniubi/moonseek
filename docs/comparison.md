# moonseek vs tantivy vs Lucene vs bleve

A feature-by-feature comparison of moonseek 0.3.0 with three established embedded/full-text
engines. The goal is a useful map, not a scoreboard: the three mature engines are decades of
engineering, and several rows below are deliberately unflattering to moonseek.

Legend: ✅ implemented and documented · ⚠️ partial, optional module, or version-dependent ·
❌ absent · (?) uncertain — the capability or its exact boundary is not publicly pinned down.

## Matrix

| Capability | moonseek 0.3.0 (MoonBit) | tantivy (Rust) | Apache Lucene (Java) | bleve (Go) |
|---|---|---|---|---|
| Inverted index | ✅ per-field postings with positions | ✅ | ✅ | ✅ |
| BM25 ranking | ✅ k1=1.2, b=0.75, per-field weight | ✅ (BM25 by default) | ✅ (BM25Similarity) | ✅ (BM25; TF-IDF also available) |
| Boolean queries | ✅ `AND`/`OR`/`NOT`, implicit AND, parentheses | ✅ | ✅ | ✅ |
| Phrase queries | ✅ positional, CJK bigrams contiguous | ✅ | ✅ | ✅ |
| Prefix queries | ✅ binary search over sorted vocabulary | ✅ (also regex/automaton) | ✅ (also regex/wildcard) | ✅ |
| Fuzzy / edit distance | ✅ Damerau-Levenshtein + **BK-tree** | ✅ Levenshtein **automaton** | ✅ Levenshtein **automaton** | ✅ Levenshtein **automaton** (vellum) |
| Faceted filtering + aggregation | ✅ filters + per-value counts + offset paging | ✅ facets collector | ✅ (facets module) | ✅ (facets builder) |
| Server-side highlighting | ✅ HTML-escaped spans, CJK codepoint offsets, snippet | ✅ snippet generator | ✅ (Highlighter module) | ✅ (fragmenter + highlighter) |
| Stored fields (original text) | ✅ `get_document` / `get_field`, in snapshot | ✅ document store | ✅ stored fields | ✅ document mapping `store` |
| Sort orders | ✅ score asc/desc, id asc/desc | ✅ fast-field sort | ✅ Sort / SortField | ✅ `SearchRequest.Sort` |
| Cursor pagination | ✅ `search_after(score, id)` | ⚠️ `DocAddress`-based paging, no built-in `search_after` (?) | ✅ `IndexSearcher.searchAfter` | ⚠️ `from`/`size`; `SearchAfter` in recent v2.5 (?) |
| Score explanation | ✅ per (field, term) tf/df/idf/norm/score | ✅ `Searcher::explain` | ✅ `Explanation` | ✅ `SearchRequest.Explain` |
| Segment-based index + merge | ✅ immutable segments + tiered merge | ✅ `LogMergePolicy` | ✅ `TieredMergePolicy` | ✅ scorch segments + merger |
| Write-ahead log / crash recovery | ✅ CRC-framed WAL, torn-tail replay, checkpoint (native) | ❌ no WAL; atomic commit via `meta.json` rename | ❌ no WAL; durability via commit points (`segments_N`) | ⚠️ no explicit WAL; durability delegated to the kv store (bolt/moss) |
| Snapshot persistence | ✅ single-file MSK3: versioned, CRC-32, atomic save | ❌ directory-based index, no single-file snapshot | ❌ directory commit, no single-file snapshot | ❌ index directory / kv store, no single-file snapshot |
| Multi-backend (native + wasm + js) | ✅ native, wasm-gc, js from one core | ⚠️ native; WASM not an official target (?) | ❌ JVM only | ⚠️ native Go only; pluggable storage backends, not language targets |
| Zero-dependency core | ✅ no FFI in the engine; one dep (`moonbitlang/async`) for native file I/O | ❌ many crates | ❌ many modules + JDK | ❌ vellum, segment, kv drivers |
| Code size (library, excl. tests) | **~4.3k LOC** (~2.5k engine core) | ~100k LOC (?) | ~10⁶ LOC with modules (?) | ~50k LOC (?) |
| Runtime / deployment | Static native binary, browser WasmGC, Node/browser JS | Native binary, library | JVM | Static Go binary |

## Row-by-row notes

**Inverted index and scoring.** All four build term → postings with document frequency and
positions, and all four score with BM25. moonseek's variant multiplies BM25 by a per-field weight
declared in the schema (`title` ×3), which tantivy expresses with per-field boosts at query time
and Lucene with `BoostQuery`/field boosts. The difference is ergonomic, not algorithmic.

**Fuzzy matching is the sharpest architectural difference.** tantivy, Lucene and bleve all compile
a Levenshtein automaton and intersect it with the term dictionary — an FST/automaton walk that is
sub-linear in vocabulary size and, crucially, does not depend on the distance distribution. moonseek
uses a BK-tree: also sub-linear for small radii, simpler to implement (~150 LOC), but its
performance depends on the tree's shape and it degrades toward a scan as `max_distance` grows.
moonseek's measured 13–1780× win over a linear scan is real; it is not a claim of parity with an
automaton, which is asymptotically better for large radii and large vocabularies.

**Persistence is where moonseek is deliberately different, in both directions.** moonseek ships a
single-file, versioned, CRC-checksummed snapshot with atomic temp-file → fsync → rename, plus a
CRC-framed WAL with torn-tail replay. None of tantivy, Lucene or bleve offers a single-file
snapshot as a first-class API — they persist an index directory, and crash safety comes from atomic
commit metadata plus the filesystem. That makes moonseek easier to embed (copy one file, load one
file) and less capable at scale (no incremental segment files on disk, no memory-mapped readers,
no commit-point concurrency). It is a trade of operational simplicity for throughput.

**Segments and merges.** All four have them, but at different maturity. moonseek's
`SegmentedIndex` freezes an active segment at a document threshold and merges by rebuilding a
compacted index from stored fields — correct and tested, but a full rebuild, not a streaming merge.
Lucene's `TieredMergePolicy` and tantivy's `LogMergePolicy` merge postings directly and are
tuned for continuous write loads. bleve's scorch merger is in the same class.

**Multi-backend.** moonseek is the only one of the four that compiles the same core to native,
wasm-gc and js with no FFI and no conditional engine code. That is its genuine differentiator: the
browser demo runs the actual engine, not a JavaScript reimplementation. tantivy has community WASM
experiments but no official target (?); Lucene is JVM-bound; bleve is Go-bound.

**Code size.** moonseek's ~4.3k library LOC (including the web export layer) is roughly two orders
of magnitude below tantivy and three below Lucene. That is a feature for auditability and a
limitation for feature depth — there is no query optimizer, no SIMD, no parallel search, no
distributed mode.

## Where moonseek is honestly weaker

These are not hedging; they are the reasons a production team would still choose tantivy or
Lucene today.

1. **No SIMD.** Scoring and edit-distance loops are scalar. tantivy and Lucene both vectorize hot
   loops and get 2–4× on saturated term scoring. moonseek leaves that on the table.
2. **Single-threaded.** One core per query, one core per indexing run. No parallel segment search,
   no concurrent writer. tantivy and Lucene both parallelize across segments.
3. **No incremental segment writes.** The measured write path is an in-memory index plus a
   whole-index snapshot. There are no per-segment files appended to disk, so reopening a large
   index means deserializing the whole image (1.7 s for 17.6 MB).
4. **No sharding / distributed search.** One process, one index. Lucene's ecosystem (Solr,
   Elasticsearch) and tantivy's `quickwit` cover this; moonseek explicitly does not.
5. **Smaller query language.** No regex, wildcard, span/near queries, range queries, or per-field
   analyzer selection. The grammar is `term`, `"phrase"`, `AND`/`OR`/`NOT`, `field:term`, `prefix*`,
   parentheses.
6. **Facets are exact-match only.** No hierarchical/path facets, no numeric range facets, no
   date histograms. Lucene and bleve both go further.
7. **No analyzer plugins.** One analyzer: Latin words + CJK bigrams. No stemming, no synonyms, no
   custom token filters.
8. **No query optimizer.** Evaluation is a straightforward recursive descent over the AST with
   per-query score-map materialization; there is no cost-based reordering or posting-list skipping.

## Positioning

moonseek is a **complete, auditable implementation for teaching and embedding**, not a
production-scale search engine. It implements the full classic feature set — inverted index, BM25,
boolean/phrase/prefix/fuzzy, facets, highlighting, stored fields, sorting, cursor pagination,
explanation, segments, WAL, snapshots — in ~4.3k lines of pure MoonBit, and it runs unchanged
native, in WebAssembly, and in JavaScript. No other engine in this table can be dropped into a
browser tab as a 44 KB snapshot and answer CJK phrase queries in single-digit milliseconds.

The honest comparison is therefore not "moonseek vs tantivy on throughput" — tantivy wins that, and
will keep winning. It is "what is the smallest complete search engine that a reader can understand
end to end, that runs everywhere MoonBit compiles, and that gets the semantics right?" On that
question, moonseek is the only full-feature implementation in the MoonBit ecosystem, and the
feature matrix above is the evidence that "full-feature" is not a marketing word: every ✅ in the
moonseek column is backed by a test in the 217-test suite and, where performance is claimed, by a
number in [benchmark.md](benchmark.md).

## Notes on uncertain cells

Cells marked (?) are places where the boundary moved recently or where public documentation is
ambiguous, and where we preferred an honest question mark to a confident guess:

- **tantivy cursor pagination** — `TopDocs` exposes `DocAddress` and offset-style collectors; a
  first-class `search_after` equivalent has been discussed but is not a stable public API in the
  versions we checked (?).
- **tantivy WASM** — community forks compile it, but it is not an officially supported target (?).
- **bleve `SearchAfter`** — added in the v2.5 line; older v2 releases only had `from`/`size` (?).
- **Code sizes** — approximate order-of-magnitude figures for tantivy, Lucene and bleve, counting
  library source without tests or generated code (?). moonseek's figure is exact:
  `wc -l` over the 16 library files plus `web/api.mbt` = 4,282 lines.
