# Changelog

## 0.17.1 (2026-11-14)

### Fixed: a checkpoint could truncate a write that had not been applied yet

The write path journalled a record, released the write lock, and only then
applied it to the in-memory index. A checkpoint could run in that gap: it
serialized an index that did not contain the record, then truncated the journal
that was the record's only copy. The write had already been acknowledged, so it
was simply gone — on restart it existed in neither the snapshot nor the journal.

The window is small and real. `tools/soak-cluster.mjs` (new) reproduced it as
one lost document in ~7,500 acknowledged writes, with the group whose primary had
been restarted mid-run: repair then removed that document from its replica, which
is what made the loss visible at all.

The journal, the apply and the checkpoint now happen inside one critical
section. Group commit carries the entries as well as the encoded frames, and the
leader applies every entry of its generation before releasing its waiters, so a
checkpoint can never observe a journal record whose apply has not happened. The
bulk path got the same treatment: its apply moved inside the lock that journals
it.

Measured against 0.17.0 on the same machine, alternating runs: 0.98× at one
writer, 1.22× at 8, 1.01× at 32 — the fix costs nothing, because the apply is
work the leader was going to do anyway.

## 0.17.0 (2026-11-14)

Durable ingest stops paying one fsync per request.

### Performance: group commit for the journal

Every accepted write fsynced its own record before being applied, so a
single-document `POST /index` was capped at ~230–300 documents per second no
matter how many connections arrived — an fsync costs the same whether it covers
one record or fifty.

The journal now commits in generations. The first writer of a burst becomes the
flusher, everyone who arrives while it is acquiring the write lock joins the same
generation, and the leader writes the whole generation with one `write` and one
fsync before releasing every waiter. A writer that arrives after the generation
is closed forms the next one.

Same machine, same session, three repetitions per level, order alternated:

| Concurrent writers | Before | After | Speedup |
|---|---:|---:|---:|
| 1 | 230 docs/s | 268 docs/s | 1.16× |
| 8 | 389 docs/s | 745 docs/s | **1.91×** |
| 32 | 323 docs/s | 1,094 docs/s | **3.38×** |

The guarantee is unchanged: every fragment still carries its own magic, length
and CRC, so a generation torn by a crash replays its complete prefix, and a caller
returns only after the flush containing its record has fsynced.
`tools/test-durability-concurrent.sh` now runs 16 concurrent writers against 25
forced checkpoints on an 800-document burst and requires every acknowledged write
after a restart.

## 0.16.1 (2026-11-14)

### Fixed: a node could not be restarted on Linux

Both listeners were created without `SO_REUSEADDR`. On Linux, restarting a
process on the port it just vacated can then fail with
`Address already in use`, and the node exits before it serves anything —
which is precisely what a supervisor, a rolling restart or a test does.
`tools/test-shard-restart.sh` found it on CI while passing on Windows, where the
option is always on. Both the HTTP server and the shard listener now pass
`reuse_addr=true`.

## 0.16.0 (2026-11-14)

The cluster got **cheaper and more honest**. Reusing shard connections removed
most of what a coordinator added: a forward write went from 2.19× a local write to
1.31×, fan-out queries from 1.62× to 1.13×, and a two-member replicated write
from 3.10× to 1.26×. Three repair/rebalance paths that reported success without
having done the work now report what happened.

### Performance: shard connections are pooled

* A coordinator dialled a fresh TCP connection for **every** shard call, so a
  replicated write paid two connects and a fan-out query paid K. The shard
  listener now serves several framed requests per connection and the coordinator
  keeps up to 8 idle sockets per address.

  Measured with `tools/bench-cluster.mjs` (3 shards, 3,000 documents, 60
  interleaved samples per query): mean coordinator/single latency ratio **1.62× →
  1.13×**; one-hop forwarded write **2.19× → 1.31×**; 2,000 documents through 3
  groups of 2 members **3.10× → 1.26×** (83 → 254 docs/s against a single node's
  320).

* A pooled socket is invalid when its shard restarts, and a dead socket looks
  exactly like a dead shard. A failed **reused** socket now gets one retry on a
  fresh connection; a failure on a fresh connection is still reported as the shard
  not answering. `tools/test-shard-restart.sh` (new CI job) restarts a shard under
  a warm pool and requires the very next query to be exact.

### Fixed: `_repair` treated "no documents" as "not there"

* **An empty primary skipped its whole group.** `cluster_repair` returned early
  when the primary reported no ids, so a replica holding a document the cluster
  had deleted was never cleaned — and would have been served after failover. An
  empty primary is now authoritative: the ghost is removed (`deferred` counts it).
* **An unreachable member was silently skipped.** `_repair` answered `ok: true`
  with no failed address while a replica was down, which reads as "the group is in
  sync" when nothing about it was inspected. Both an unreachable primary and an
  unreachable replica are now named in `failed_addresses` with `ok: false`.
* `group_ids` returns whether the member answered at all, instead of folding
  "empty" and "unreachable" into the same empty list.

`tools/test-repair-edge.sh` (new CI job) builds both states and asserts on them.

### Fixed: `_rebalance` did not report shards it could not read

`cluster_ids_by_shard` turned a shard that failed its `ids` request into an empty
id list, which a migration reads as "nothing to move". A rebalance that relocated
three of four shards could therefore report success. The unreachable addresses are
now carried into the report's `failed_addresses`, so a partial migration is
visibly partial.

### Durability

* **A checkpoint serialized the index twice** — once to report a size and once to
  write it. `journal_checkpoint` now returns the byte count from the snapshot it
  wrote, halving the serialization work on the one path that touches the whole
  index. `POST /_checkpoint` also reports `took_ms`.
* Journal appends and checkpointing are serialized by a write lock. A checkpoint
  yields between writing the snapshot and truncating the journal, and a record
  appended in that window is in the snapshot only if the snapshot serialized its
  apply — while the truncate erases its journal record either way. The lock makes
  "the journal is empty" mean "the snapshot contains everything".
  `tools/test-durability-concurrent.sh` (new CI job) runs 6 concurrent writers
  against 25 forced checkpoints on a 6,000-document index and requires every
  acknowledged write after a restart. The window could not be provoked on this
  machine even with the lock removed, so this is recorded as an explicit
  invariant rather than as a fix for an observed loss.

### Documented

* `GET /_dfs?q=…` was implemented and documented nowhere; it now has an
  `docs/api.md` section, and the response shape is pinned by a live check.
* `POST /_repair`'s empty-primary and unreachable-member semantics are in
  `docs/api.md` and `docs/cluster.md`.
* `docs/cluster.md` no longer claims one request per connection.

## 0.15.1 (2026-11-13)

### Fixed

* **A phrase driven by its second term matched the wrong documents.** The 0.15.0
  rewrite walks the *rarest* term's postings, but `exact_phrase_count` was handed
  the driver's posting and so walked position offsets relative to the driver
  instead of relative to term 0. For `"common rare"` where `rare` is the rarer
  term, that changed which documents matched.

  The unit tests did not catch it — their phrases happened to have the first term
  rarest. The **quality gate** did: NDCG@10 on the 3,698-package corpus fell from
  0.9045 to 0.8538, and CI's "committed report must match the measurement" step
  failed. The fix passes `aligned[0]` (term 0's posting for the document) to the
  position walk; driving on the rarest term remains a traversal choice only. All
  six ablation configurations match the committed report again.

  A regression test now pins a phrase whose second term is the rare one, with an
  explicit expected id list, so the traversal choice cannot silently change
  answers again.

## 0.15.0 (2026-11-13)

The service now **survives a restart**, and the two query shapes that were doing
unnecessary work got rewritten. Phrases are ~24× faster, a one-term prefix ~5×,
and durable bulk ingest costs ~1.2–1.3× in-memory instead of nothing-at-all being
persisted.

### Durable service (`--data-dir`)

The server could load a snapshot with `--index` but never wrote one, so every
document ingested since startup was lost on restart. `--data-dir DIR` closes
that:

* `journal.log` — one CRC-framed record per accepted write, appended with a data
  fsync **before** the in-memory apply, so a crash between the two replays the
  record instead of losing it. A torn tail replays only the complete prefix.
* `index.msk` — the checkpoint: temp file → fsync → atomic rename, then the
  journal is truncated. `POST /_checkpoint` forces one; it also happens
  automatically every 10,000 records.

The record carries the **whole** accepted write — text fields, facets, numeric
columns and vectors — because the engine's own `Document` WAL only carries text,
and replaying that would silently drop the rest and change search results after
a restart. Replay reuses the same apply function as the live path, so the two
cannot drift. `--index` and `--data-dir` are mutually exclusive; a coordinator
never journals because it owns no documents.

A bulk batch shares **one** fsync: each record keeps its own CRC frame, so a torn
batch still replays its complete prefix. That took durable ingest from ~2.6×
in-memory (one fsync per document) to ~1.2–1.3× (219–249 ms vs 250–289 ms for
2,000 documents, server-side `took_ms`, min of four runs). A single-document
write still pays one fsync — there is nothing to share it with.

`tools/test-durability.sh` restarts the process and asserts that text, facets,
numbers, vectors and deletions all come back, that the checkpoint truncates the
journal, and that a server without `--data-dir` returns 400 from `/_checkpoint`
rather than pretending. It runs in CI as a fifth end-to-end job.

### Phrases: walk the rarest term, not every term

`eval_phrase` built a `doc -> Posting` hash map for *every* term on *every*
query — thousands of hash inserts on a saturated term before a single position
was compared. It now walks the rarest term's doc-sorted list and probes the
others with forward-only cursors, so the cost follows the phrase's candidates
rather than the sum of the terms' document frequencies. `explain`'s phrase count
binary-searches the one document it is asked about instead of building maps.

Measured on 20k documents, `--release`, `bench/query`: `"search engine"`
**7.07 → 0.29 ms** (~24×), `"search engine"~3` **9.80 → 1.04 ms** (~9×), and
`"search w4998x"` (dense + rare) 0.04 ms — about what the rare term alone costs.

### Prefixes: one term is a term, many terms merge over a heap

A prefix expanding to exactly one dictionary term (`seg*` → `segment`) is a
single-term query, so it takes the block-max path: **2.34 → 0.44 ms**. The check
counts distinct terms across fields and stops at the second, so a broad prefix
costs a couple of dictionary probes. A prefix matching several terms merges their
doc-sorted lists over a **min-heap**; a first attempt scanned every cursor for the
smallest document, which is O(k) per document and made `w49*` (~1,100 terms)
*slower* than the sort it replaced. The heap makes it O(log k) per posting.

Both prefix paths are pinned against the exact evaluator, with deletions and a
prefix that matches nothing.

### Added

* `JournalDoc` / `JournalEntry`, `journal_encode` / `journal_decode` (portable),
  `journal_append` / `journal_append_many` / `journal_replay` /
  `journal_checkpoint` / `journal_has_snapshot` / `journal_load_snapshot`
  (native).
* `bench/query`: a harness for the compound query shapes against the single terms
  they are built from, reporting p50/p90/min.
* Tests: 355 native, 299 wasm-gc, 299 js (was 341 / 290 / 290).

## 0.14.0 (2026-11-12)

Block-max WAND now covers **disjunctions** — where it is a measured win on the
shape it suits and is gated off where it is not — and vector search keeps its
points in a cached buffer instead of rebuilding them on every query.

### Disjunction block-max WAND

`a OR b` previously scored every posting of every term. `Index::or_terms_topk`
walks the union in blocks of 16 with the same bound test the single-term and
conjunction paths use: a block is skipped, without scoring its documents, when
the terms' summed block maxima cannot reach the current k-th best. Documents hit
by several terms are summed once, in query order, so the result equals the exact
union bit-for-bit (asserted over 8 queries × 4 limits, plus deletions).

The walk is not unconditionally faster, so `search` takes it only when
`Index::or_walk_pays` says the union has something to skip. Measured on 20k
documents at `--release`, min of 200 interleaved samples:

| union | walk | exact merge |
|---|---:|---:|
| one dense (df 4021) + four rare (df 285) | **2.38 ms** | 3.64 ms |
| one dense + eight rare | **3.96 ms** | 4.51 ms |
| two comparably dense | 4.14 ms | 4.64 ms |
| three comparably dense | 11.59 ms | **10.50 ms** |
| eight rare, no dense operand | 1.09 ms | **0.61 ms** |

One dense operand keeps the summed bound above the threshold everywhere, so
nothing is skipped and the per-document cursor bookkeeping is pure loss; a union
with *no* dense operand is short enough that the plain merge is already cheapest.
The gate asks for an operand at least ten times rarer than the densest, which
separates all five rows, and the tests pin both sides of it. It is a performance
choice only: the paths return identical results.

### Cached vector points

`HnswPoints` was rebuilt on every kNN query, so a search paid a full 5,000-vector
flatten before touching the graph. The flattened buffer is now cached per field
(a `points_cache` invalidated by `set_vector`, like the block stats and the
HNSW graph) and `knn_exact` iterates it directly. The rebuild — 4.29 ms on the
5,000 × 64 index — is paid once per mutation instead of once per query.

### Changed

* `Index::or_walk_pays` and `Index::or_terms_topk` are public;
  `Index::knn_exact_ids` returns similarity-sorted `(id, score)` pairs.
* The stress bench measures two query variants **interleaved** (both timed within
  each sample) and reports the **minimum** sample next to p50, so a contended
  machine cannot dress noise up as a speed-up. Its disjunction rows compare the
  walk against the exact merge directly and print which the gate selects.

## 0.13.0 (2026-11-12)

Block-max WAND now covers **conjunctions**, and the scoring loop around it lost
the work that was actually costing time. Together: a saturated single term is
3–4× faster than the full scan, `search AND engine` ~1.5×, the three-term case
~2×, and all of it bit-for-bit identical to the exact evaluation.

### Conjunctions

`a b` / `a AND b` no longer evaluate every term fully. The shortest term's
posting list drives a leapfrog walk: only its documents can match, so the other
terms are asked "are you at this document?" through forward-only cursors instead
of being enumerated — a saturated term is never fully walked. A driver block is
skipped when the *sum* of the terms' block maxima cannot reach the threshold, and
scores are summed in the query's term order, which is the order the exact
evaluator's nested intersections sum in.

Measured on 20k documents (`bench/stress/main.mbt`), p50 of 200 samples:
`search AND engine` 2.85–3.51 ms against 4.27–5.60 ms; `moonbit AND search`
2.43–2.84 ms against 4.58–5.55 ms; `search AND engine AND index` 4.07–4.25 ms
against 7.24–9.63 ms. Single saturated terms improved too (0.47–1.06 ms against
2.30–2.94 ms) once the loop was cleaned up.

### The scoring loop

MoonBit's core library exposes only an experimental, hidden `v128_load` and no
SIMD arithmetic intrinsics, so a hand-vectorised BM25 loop would need FFI or a
third-party dependency — both against this project's "pure MoonBit, two
dependencies" design. The time was somewhere else anyway: a `Hit` was being
allocated for every candidate scored (thousands, to keep ten), the block bound
was computed for all 1,250 blocks when postings occupied ~250 of them, and the
single-field case built an intermediate array per block. All three are gone; the
single-term path went from 1.29 ms to 0.47–0.83 ms on that change alone.

### Fixed

* **A block bound could land one ulp below a posting's score.** The bound is
  computed from factored terms while a posting's score is one expression, and on
  a corpus with a huge tie group sitting on the cut, the low bound skipped a
  document that tied with the k-th best — and would have won the id tiebreak.
  The bound is now inflated by one part in 1e12, which can only make a block
  *less* likely to be skipped. Found by the new multi-term equality test, which
  includes exactly that corpus.

### Added

* `Index::and_terms_topk`; `search` routes a bounded conjunction through it and
  a bounded single term through `term_topk_blockmax`. Three new tests (334 -> 337).

## 0.12.0 (2026-11-12)

Three additions: a **one-command demo**, a **shot list for a demo video**, and
**Block-Max WAND** for saturated single-term queries — the last documented
`O(df)` cost, now measured at ~2.3× on the saturated case.

### Block-max top-k

`Index::search` on a bounded single-term query no longer scores every posting.
The doc-sorted list is walked in blocks of 16, and once the top-`k` set is full
a block is skipped when the highest score any posting in it can reach is
**strictly** below the current k-th best. The bound is the block's exact
maximum, computed once and cached, and the strict inequality means a posting
that only ties is still scored and can still win the id tiebreak — so the result
is bit-for-bit the full scan. Six engine tests assert that equality over a
corpus, field-scoped and across fields, with deletions, and assert that the
skipping actually fires so it cannot silently regress to a no-op.

Measured on 20k documents (`bench/stress/main.mbt`): 72–74% of postings skipped,
p50 **1.24–1.29 ms** against 2.79–3.02 ms for the exact path. It applies to
single-term queries; multi-term queries still evaluate exactly, and the skip
rate is corpus-dependent — both stated in `docs/benchmark.md`.

### One-command demo

* `tools/demo.sh` builds if needed, starts a replicated cluster (primary +
  replica per group), ingests the corpus through the coordinator, and serves the
  console — then prints the URLs and waits.
* `tools/demo-story.sh` is the whole story as a script: start, load, search,
  `dfs`, hybrid retrieval, grow 3→4 groups without a reindex, repair a diverged
  member, kill a primary (invisible failover), kill its replica (honest
  degradation). It is the thing to screen-record, and `docs/demo-video.md` is
  the shot list with narration in both languages.

### Added

* Engine: `Index::term_topk_blockmax`, `Index::search_exact` (the full-scan path
  the shortcut is measured and tested against), `BLOCK_SIZE`, per-term block
  statistics. 334 tests.

## 0.11.0 (2026-11-12)

Hybrid retrieval — BM25 fused with vector kNN — now works on a coordinator.
This closes the last item in the distributed gap list that was a *missing
capability* rather than an operational nicety, and it is exact rather than
"close enough": the coordinator builds the same two global rankings a single
node would and calls the same fusion function, so there is one implementation
and nothing to drift.

### Cross-shard hybrid retrieval

`GET /search?knn=emb:0.1,0.2,…&knn_k=50` on a coordinator now:

* gathers corpus-wide statistics unconditionally (a hybrid query that skipped
  `dfs` would fuse rankings from two different scales),
* takes each shard's top-k vectors via a new `{"op":"knn"}` shard request,
  merging them by cosine similarity — comparable across shards, so the union of
  per-shard top-k contains the true global top-k,
* fuses the two global lists with **`fuse_rankings`**, the very function
  `Index::hybrid_search` calls.

Measured (`tools/test-cluster.sh`, claim 8): 300 documents with vectors indexed
once on a single node and once through the coordinator onto three shards; five
queries with `knn_exact=true` on both sides — **ids and per-hit
`lexical_rank`/`vector_rank` identical, 5/5**. `knn_exact` is what makes that a
statement about the fan-out instead of about two HNSW graphs; the default graph
path is approximate per shard, and `Index::knn_recall` measures that bound.

### Fixed

* **The query-string `knn` parameter was documented but never parsed.** The
  handler only read the JSON-body form, so `GET /search?knn=…` silently behaved
  like a plain BM25 query — the same "documented but not wired" shape as the
  `sort` bug in 0.9.0. Both forms now work, and the body still overrides.
* A malformed coordinate is skipped rather than folded in as zero: a bad float
  would otherwise become a real 0.0 and quietly move the query vector.

### Added

* Engine: `fuse_rankings` (the fusion step, now shared), `Index::knn_exact_ids`
  (deterministic id-keyed brute force), and an `exact` switch on
  `Index::hybrid_search`.
* Shard op `knn`; coordinator `cluster_knn` with the same per-shard pooling and
  failure accounting as search.
* Three unit tests (fusion reconstruction, exact-id ordering, shard-reply
  parsing) and claim 8 in the cluster end-to-end test. 328 tests.

## 0.10.0 (2026-11-12)

The distributed layer is finished in the sense that it can now be *operated*:
a cluster grows without a reindex, a member that missed writes is brought back,
and several coordinators can share the load. Every claim below is an end-to-end
test with its own CI job, and the "what is not implemented" list in
`docs/cluster.md` was rewritten around what is genuinely still missing rather
than around what happened to be built.

### Growing a cluster

`POST /_rebalance?from=N` moves the documents the new ring assigns elsewhere.

Measured on 3,000 documents (`tools/test-rebalance.sh`): the planner predicted
**762 moves (25.4%)**, the executor moved **762**, and the four shards ended at
**840/738/660/762** — *exactly* the distribution the plan had predicted, holding
3,000 documents between them. Afterwards `/_plan?shards=4` reports **0 to move**
and a second rebalance moves nothing: that pair is what makes a partial or
repeated run safe instead of a way to lose or duplicate documents.

Two decisions carry it:

* **Write, acknowledge, then delete.** Each document is written to its new owner
  and acknowledged by *every* member of that group before it is removed from its
  source. A document in two places is recoverable by re-running; one deleted from
  its source before its destination had it is gone. Anything not fully
  acknowledged is counted in `deferred` and left alone.
* **Migration uses the client's own wire format.** Documents are rebuilt from the
  index into the same JSON `POST /index` accepts, vectors included. A rebalance
  that moved a document's text but not its vector would leave the destination
  answering text queries and silently missing vector ones — so `Index::get_vector`
  and `Index::vector_fields` now exist, and the round trip is a property of the
  format rather than of the migration code.

### Repairing a member

`POST /_repair` brings every member back in line with its group's primary, in
**both** directions: a member missing a document gets it, and a member holding one
the primary does not have loses it. Repairing one direction only would leave a
replica reporting a different total from its primary — the state failover must not
be in.

Measured (`tools/test-repair.sh`): a replica is down while the cluster takes 3,000
writes (honestly reported as `members_ok: 5, members: 6` with the dead address
named, not as a success), comes back holding **0** against its primary's 1,007,
then `/_repair` copies **exactly those 1,007** and all three groups agree. A
document written directly to that replica is removed by the next repair, and
killing the group's primary afterwards leaves the cluster's answer byte-identical.

### Several coordinators

Two coordinators started with the same `--shards` answer three queries identically
and identically to a single node under `dfs=true`; killing one leaves the other
serving. The coordinator owns no state, so this is what the design already
implied — but it is now measured, and what is *not* solved (automatic agreement on
the shard map) is stated rather than implied.

### Added

* Shard ops `export`, `has`, `delete_many`, and the `bulk` form that repair and
  migration use.
* Engine: `Index::get_vector`, `Index::vector_fields`.
* Five unit tests pinning the planner and the executor to the same selection rule,
  and to the ring arrays summing to the corpus. 325 tests.
* Two CI jobs (`rebalance`, `repair`) and claim 7 in the cluster test.

### Fixed

* `member` is a **reserved keyword** in MoonBit, like `local` and `method`; the
  repair code used it as a variable and a parameter name.
* `tools/test-repair.sh` killed the primary through `pgrep`, which does not exist
  in Git Bash — the failover step passed vacuously until it used the PID recorded
  at startup.


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