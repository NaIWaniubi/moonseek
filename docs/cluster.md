# Distributed search

moonseek runs as one process, as a **shard**, or as a **coordinator**. The same
binary does all three; the flags decide which.

```bash
# three shard groups, each a primary and a replica, each also serving HTTP
moonseek-server --addr 127.0.0.1:7801 --shard-port 127.0.0.1:7901 &
moonseek-server --addr 127.0.0.1:7802 --shard-port 127.0.0.1:7902 &
moonseek-server --addr 127.0.0.1:7803 --shard-port 127.0.0.1:7903 &

# a coordinator: owns no documents, fans writes and queries out
moonseek-server --addr 127.0.0.1:7805 --pool 200 \
  --shards "127.0.0.1:7901|127.0.0.1:7904,127.0.0.1:7902|127.0.0.1:7905"
```

A `|` after a primary declares its replicas, in preference order.
`--shard-mode ring|modulo` picks the placement rule (default `ring`, see below)
and `--vnodes N` sets the ring's virtual nodes per shard.

## Why the coordinator owns nothing

The coordinator holds no index. That is the design decision the rest of this
document follows from.

If the coordinator kept a slice of the corpus too, then losing it would mean
losing *data* rather than capacity, and its own slice would need to shrink when a
peer died — so every failure path would need a special case for "the shard that
happens to be me". Owning nothing keeps one rule: a shard's answer is either in
the merge or in the failure list, and the coordinator's health never depends on
which. It also means a coordinator can be replaced by any other process without
moving a document.

## Sharding: a consistent hash ring

A document's shard is decided by a hash of its **id and nothing else**. The id is
the only input, so the assignment is stable across restarts and across processes:
a document written twice lands on the same shard both times, and a coordinator
that reassigned on restart would leave two copies on different shards and return
the document twice.

Two rules are implemented, and the second exists to be measured against:

| rule | how | 3 → 4 shards over 3,000 documents |
|---|---|---:|
| `modulo` | `hash(id) % shards` | **74.9%** of documents move |
| `ring` (default) | first ring point clockwise | **24.2%** move |

Modulo renumbers every key when the divisor changes, so growing the cluster
rewrites nearly the whole corpus. The ring gives each shard 128 *virtual nodes*,
so adding a shard only takes over the arcs its new points fall on — about `1/N` of
the keys, which is 25% for 3 → 4. Both numbers are measured from the real document
ids by `GET /_plan?shards=4`, not estimated.

The ring is also even. Over the 3,000-document corpus the shards take
**969 / 1024 / 1007** documents (ideal 1,000 each); over 20,000 sequential ids,
**6350 / 6831 / 6819**.

### Getting the hash right took three fixes, all of them silent

The ring is only as good as the hash under it, and all three of these bugs
produced a working-looking cluster:

1. **The offline splitter was not computing FNV-1a at all.** It wrote
   `hash * 16777619` in JavaScript, where the product of two 32-bit values reaches
   7.2e16 — past `Number.MAX_SAFE_INTEGER` — so it rounded. It went unnoticed
   because the coordinator queried every shard regardless of where a document
   "should" be, so placement never had to be right. `Math.imul` fixes it, and the
   two implementations are now pinned to each other by a golden test
   (`tools/shard-hash-vector.mjs` prints the vectors;
   `server/cluster_wbtest.mbt` asserts them).
2. **The MoonBit hash ran over UTF-16 code units** (`String::to_array`) while the
   splitter hashed UTF-8 bytes. Those agree for ASCII, which every generated id
   was, and disagree for Chinese ones. Both hash UTF-8 now.
3. **FNV-1a alone is linear in the input bytes.** `pkg/1`, `pkg/2`, … differ only
   in the last byte, so their hashes sit in an arithmetic progression with step
   `16777619` — and a *ring built from such keys* measured **29% / 21% / 50%**
   behind three shards. Harmless for `hash % N`, fatal for a ring. MurmurHash3's
   `fmix32` finalizer breaks the linearity: the same ring then measures
   **36% / 28% / 36%** of the ring by arc, and real id sets land within 5%.

The lesson is that a hash used for placement needs a distribution test, not just
a determinism test.

### Placement is checkable from outside

| endpoint | answers |
|---|---|
| `GET /_ring` | the rule, the ring size, and how the points divide across shards |
| `GET /_placement?id=…` | which shard group owns that id, and its primary |
| `GET /_plan?shards=N` | how many documents would move, ring vs modulo, from the real ids |

`tools/test-cluster.sh` asserts that the splitter and the coordinator agree
document by document: it asks `/_placement` about one document the splitter filed
on each shard. That check is what makes "the cluster equals a single node" a real
statement rather than a comparison of two corpora.

## Writes: routing and replication

A write to a coordinator is routed to the group that owns the id and sent to
**every member of that group**, in parallel:

```
POST   /index        -> owning group, replicated
DELETE /index?id=…   -> owning group, replicated
POST   /index/bulk   -> grouped by owning shard, one request per shard
```

Replication on the write path is what makes a replica a replica. Before it
existed, a replica was only correct if someone seeded it by hand, so the failover
path answered from stale data while reporting success — the worst kind of failure,
because it looks like a working cluster.

Bulk groups the batch instead of forwarding it whole. A shard that received the
entire batch would index documents it does not own, and then several shards would
answer for the same document.

**`ok` in a write reply means every member applied it.** A write acknowledged by
one member of three is not durable, and is reported as `"ok": false` with the
counts and the addresses that missed it. `members_ok`/`members` carry the same
information for a bulk load.

Measured (`tools/test-replication.sh`, its own CI job): 3 primaries + 3 replicas,
3,000 documents written **through the coordinator**:

```
{"indexed":3000,"failed":0,"shards":3,"members_ok":6,"members":6,"took_ms":152}
```

Every primary and its replica hold identical shares — 969/969, 1024/1024,
1007/1007. Killing a primary then leaves total, ranking and shard accounting
byte-identical, because the replica already had the data; killing the whole group
reports `ok: 2, failed: 1` and the total drops 2376 → 1609.

## The shard protocol

One JSON request per TCP connection, length-prefixed with a 4-byte little-endian
header, one JSON reply, then close.

| op | request | reply |
|---|---|---|
| `ping` | `{"op":"ping"}` | `{"ok":true}` |
| `docs` | `{"op":"docs"}` | `{"docs":N}` |
| `ids` | `{"op":"ids"}` | every live id, for the rebalance planner |
| `index` | `{"op":"index","body":"<document json>"}` | what `POST /index` returns |
| `bulk` | `{"op":"bulk","body":"<ndjson>"}` | what `POST /index/bulk` returns |
| `delete` | `{"op":"delete","id":"…"}` | what `DELETE /index` returns |
| `search` | `{"op":"search","query":…,"limit":N,"filters":[…][,"stats":{…}]}` | `{"hits":[["id",score],…],"docs":N,"total":M}` |
| `stats` | `{"op":"stats","terms":[["term","field"],…]}` | per-term `df`, per-field length sums and counts |
| `agg` | `{"op":"agg","query":…,"specs":[…],"filters":[…],"values":[…]}` | per-shard aggregation results, plus raw values |

Two framing details are load-bearing:

* **Length prefix, not newline framing.** Reading until EOF deadlocks against a
  client that sends a request and then waits for the reply — the server waits for
  a close that never comes. Both directions carry the same 4-byte prefix.
* **UTF-8 on the wire.** `String::to_bytes` in MoonBit is UTF-16LE, so a reply
  decoded with the matching `Bytes::to_string` reads back as one character per two
  bytes. Both sides use `@utf8`.

## Scatter-gather, and the two scoring modes

A query asks every shard for its own top `pool` (default 200) in parallel, then
merges and cuts to `limit`. Per-shard failures are collected, not raised: a
partial answer with an explicit failure count is more useful than an error, and
the count is what tells a client the answer is partial.

```json
"shards": { "total": 3, "ok": 2, "failed": 1,
            "failed_addresses": ["127.0.0.1:7901"] }
```

The merge is correct only if each shard returns at least `limit` candidates, so
`pool` is raised to `limit` when a client asks for more than the pool.

Then there is the part that decides whether the cluster is *consistent*.

### Default: local statistics, one round trip

Each shard scores with its own `N`, `df` and `avgdl`. That is what a shard knows,
and it costs one round trip. It also means the same document scores slightly
differently depending on which shard holds it, because a term is rarer in a
1,000-document shard than in a 3,000-document corpus.

### `?dfs=true`: global statistics, two round trips

The coordinator first gathers `df`/`avgdl`/`N` from every shard, then asks each
shard to score with those numbers installed (`Index::set_external_stats`, Heaps'
`dfs_query_then_fetch`). The ranking then equals a single-node index of the same
corpus.

Measured on 3,000 documents in 3 shards, top-10
(`node tools/check-cluster.mjs`, all five processes on one machine):

| query | ids == single node | max score difference | coord ms | single ms |
|---|---|---:|---:|---:|
| `parser` | yes | 0 | 6.2 | 3.7 |
| `compiler AND gc` | yes | 0 | 6.0 | 3.4 |
| `"zero-copy"` | yes | 0 | 6.0 | 3.4 |
| `scheduler OR allocator` | yes | 0 | 7.0 | 4.9 |
| `tensor` | yes | 0 | 7.4 | 4.7 |
| `socket cache` | yes | 0 | 6.8 | 4.1 |
| `lexer parser graph` | yes | 0 | 6.7 | 4.9 |
| `minimal matrix` | yes | 0 | 5.7 | 2.3 |

**8/8 identical, worst per-hit score difference 0.000e+0.** (The first query of a
cold coordinator measured 51.6 ms — process start-up, not the query path.)

Steady state, medians over 320 requests per configuration:

| configuration | p50 | p90 |
|---|---:|---:|
| single node, 3,000 docs | 5.3 ms | 26.4 ms |
| 3 shards, local statistics | 5.8 ms | 26.9 ms |
| 3 shards, `dfs=true` | 9.5 ms | 31.2 ms |

The coordinator is within half a millisecond of the single node while doing three
times the network work, because each shard searches a third of the corpus and the
round trips run in parallel. Globally consistent scoring costs one extra round
trip, ~3.7 ms here.

Those latencies are worth a caution: all five processes are co-resident on one
machine and the p90s are dominated by machine noise. The same configuration
measured 5.3 ms or 14.2 ms p50 depending only on whether it was measured first.
That is why the *identity* results above are the ones to quote — they are exact,
not statistical.

For contrast, local-statistics mode returns a *different* ranking — measured score
deltas up to 0.82 against the single node, and 0/8 identical rankings. That is the
honest baseline: the two-phase path is not a micro-optimization, it is the
difference between a ranking and an approximation of one.

### What `dfs=true` refuses to do

A **prefix query** expands against whatever dictionary a shard happens to hold, so
two shards would gather statistics for different term sets and the merge would mix
two rankings. The coordinator detects this (`scoring_terms` returns None for a
prefix) and answers with `"dfs": false` plus
`"dfs_note": "query has shard-dependent terms (prefix); dfs not applied"` rather
than pretending. The same applies to hybrid (`knn`) retrieval, which is not fanned
out at all.

## Aggregations: merged, not approximated

`facets` and `aggs` are computed over the whole corpus by fanning the request out
and merging. A facet is an uncapped terms aggregation over the filtered result
set, so facets and aggregations share one fan-out and one merge.

The merge rules differ per aggregation kind, and the differences are the point:

| kind | rule | exact? |
|---|---|---|
| `terms` | sum counts per value, sort, **then** cap | exact |
| `stats` | count/sum add; min/max take the extreme; avg **recomputed** | exact but for FP summation order |
| `histogram` | sum per bucket, ordered by bucket index, not label text | exact |
| `percentiles` | ship the **raw values**, recompute on the union | exact |

Three of these are traps that produce plausible numbers:

* **Terms must not be capped per shard.** A value that is rank `size+1` inside one
  shard can be in the global top `size`. Shards are asked for `size: 0` and the cap
  is applied to the merged list. Same argument as the search pool size.
* **Never average the averages.** Two shards with means 2.0 and 30.0 give 16.0; the
  mean of the union is 28.7. `StatsAgg` merges counts and sums and divides at the
  end.
* **A percentile cannot be merged from summaries at all.** Two shards with medians
  2 and 20 and disjoint ranges: averaging gives 11.0, the median of the union is
  6.5. So percentiles ship values — the one aggregation that moves data rather
  than counts, and the reason `Index::agg_values` and `percentiles_of` are public.

Measured: `tools/check-distributed-aggs.py` compares a coordinator against a
single node holding the same corpus, with the tolerances stated above — buckets
and count/min/max exact, sum/avg and percentiles within a relative 1e-9 for
floating-point summation order. `tools/test-cluster.sh` runs it three times: plain,
under a filter, and over a query that matches nothing. All three report
**DISTRIBUTED AGGREGATIONS MATCH THE SINGLE NODE**.

Writing that comparison found a bug it was not looking for: **the coordinator
ignored filters for ranking and total.** Filters reached the aggregation path but
never the search request, so a filtered query returned the unfiltered total — 2376
where a single node returned 1190 — and ranked documents the filter excluded. The
filters now travel with the search request and the shard applies them through
`search_faceted`, which also returns the filtered match count.

## Failover

Two mechanisms, both measured.

**Replica takeover.** A shard group is `primary|replica|replica`; the coordinator
tries them in order and uses the first that answers. Killing the primary of a
replicated group left the result byte-identical — same total, same ranking, same
`shards.ok: 3` — because the replica answered with the same data, written there by
the coordinator's own write path.

**Partial answers.** Killing a group with no surviving member dropped the total
from 2376 to 1609 and reported `ok: 2, failed: 1` with the dead address named. The
coordinator kept serving; the client can see that the answer is partial. A search
can be complete while its aggregation is not, so an aggregation that lost a shard
is reported separately in `agg_failed_addresses` rather than folded into the
search's accounting.

The failure path needed a real fix to get there. `TaskGroup::spawn` defaults to
`allow_failure=false`, where a child task raising cancels the whole group and the
failure propagates into the request handler — so the first version of this took
the *coordinator* down along with the shard. Scatter-gather spawns with
`allow_failure=true`: a shard's failure is data for the merge step.

## What is not implemented

1. **No rebalancing executor.** `GET /_plan` reports exactly what would move if the
   shard count changed, and which documents; moving them is left to an operator.
   There is no background transfer and no way to serve a query across a
   half-migrated ring.
2. **No coordinator failover.** One coordinator is a single point of failure.
   Running two would need leader election, which is not here.
3. **Writes are replicated but not transactional.** A write that reaches one
   member of three is reported as not-ok, but there is no rollback and no repair:
   the members that missed it stay behind until written again. Replica recovery is
   a re-index, not a log.
4. **No write-ahead log on the coordinator.** A coordinator restart loses nothing
   important (it holds no state), but an in-flight bulk load whose shard dies
   mid-batch is reported, not retried.
5. **`knn`/hybrid retrieval is not fanned out.** Fusing two rankings that live on
   different shards needs per-shard vectors and a second merge, which is a
   different design.
6. **Cross-shard `sort: num:<field>` is not implemented.** Sorting applies within a
   shard's candidate pool only, so a globally correct sort by a numeric field is
   not claimed.
