# Distributed search

moonseek runs as one process, as a **shard**, or as a **coordinator**. The same
binary does all three; the flags decide which.

```bash
# three shards, each owning a slice of the corpus, each also serving HTTP
moonseek-server --addr 127.0.0.1:7801 --shard-port 127.0.0.1:7901 &
moonseek-server --addr 127.0.0.1:7802 --shard-port 127.0.0.1:7902 &
moonseek-server --addr 127.0.0.1:7803 --shard-port 127.0.0.1:7903 &

# a coordinator: owns no documents, fans queries out
moonseek-server --addr 127.0.0.1:7805 \
  --shards "127.0.0.1:7901,127.0.0.1:7902,127.0.0.1:7903"
```

Replicas are declared with `|` after a primary:
`--shards "127.0.0.1:7901|127.0.0.1:7905,127.0.0.1:7902"` means "shard 1 lives on
7901 with a replica on 7905".

## Why the coordinator owns nothing

The coordinator holds no index. That is the design decision the rest of this
document follows from.

If the coordinator kept a slice of the corpus too, then losing it would mean
losing *data* rather than capacity, and its own slice would need to shrink when
a peer died — so every failure path would need a special case for "the shard
that happens to be me". Owning nothing keeps one rule: a shard's answer is
either in the merge or in the failure list, and the coordinator's health never
depends on which.

## Sharding

Documents are assigned by **FNV-1a over the document id, modulo the shard
count**. The hash is over the id and nothing else, so the assignment is stable
across restarts and across processes: a document written twice lands on the same
shard both times. A coordinator that reassigned on restart would leave two copies
of a document on different shards, and a search would return it twice.

`tools/make-shard-corpus.mjs` generates a corpus and splits it with the *same*
hash implementation, which is what makes the cluster-vs-single-node comparison
below a meaningful test rather than a comparison of two different corpora.

Adding shards therefore reshuffles: this is modulo sharding, not consistent
hashing. A cluster that must grow without moving existing documents needs a
hash-ring, which is not implemented here and not claimed.

## The shard protocol

One JSON request per TCP connection, length-prefixed with a 4-byte
little-endian header, one JSON reply, then close.

Deliberately small — four operations:

| op | request | reply |
|---|---|---|
| `ping` | `{"op":"ping"}` | `{"ok":true}` |
| `docs` | `{"op":"docs"}` | `{"docs":N}` |
| `index` | `{"op":"index","body":"<document json>"}` | the same shape `POST /index` returns |
| `search` | `{"op":"search","query":"…","limit":N[,"stats":{…}]}` | `{"hits":[["id",score],…],"docs":N,"total":M}` |
| `stats` | `{"op":"stats","terms":[["term","field"],…]}` | per-term `df`, per-field length sums and counts |

Two framing details that are load-bearing:

* **Length prefix, not newline framing.** Reading until EOF deadlocks against a
  client that sends a request and then waits for the reply — the server waits for
  a close that never comes. Both directions carry the same 4-byte prefix.
* **UTF-8 on the wire.** `String::to_bytes` in MoonBit is UTF-16LE, so a reply
  decoded with the matching `Bytes::to_string` reads back as one character per
  two bytes. Both sides use `@utf8`.

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

Measured on 3,000 documents in 3 shards, 8 queries, top-10
(`node tools/check-cluster.mjs`):

| query | ids identical to single node | max score difference | coord ms | single-node ms |
|---|---|---:|---:|---:|
| `parser` | yes | 0 | 96.1 | 9.2 |
| `compiler AND gc` | yes | 0 | 51.5 | 4.3 |
| `"zero-copy"` | yes | 0 | 54.5 | 3.9 |
| `scheduler OR allocator` | yes | 0 | 52.8 | 4.5 |
| `tensor` | yes | 0 | 43.8 | 3.4 |
| `socket cache` | yes | 0 | 43.6 | 3.5 |
| `lexer parser graph` | yes | 0 | 52.1 | 4.7 |
| `minimal matrix` | yes | 0 | 46.4 | 3.3 |

**8/8 identical, zero score difference.** Those millisecond figures are a single
run under load; the steady-state comparison below is the one to quote.

Steady state, 30 queries per configuration, p50/p90 of round-trip latency:

| configuration | p50 | p90 |
|---|---:|---:|
| single node, 3,000 docs | 4.7 ms | 7.1 ms |
| 3 shards, local statistics | **6.7 ms** | 8.0 ms |
| 3 shards, `dfs=true` | **6.9 ms** | 7.9 ms |

The coordinator is within ~2 ms of the single node while doing three times the
network work, because each shard searches a third of the corpus and the round
trips run in parallel. Globally consistent scoring costs about 0.2 ms on top.

For contrast, local-statistics mode returns a *different* ranking — measured
score deltas up to 0.82 against the single node, and 0/8 identical rankings.
That is the honest baseline: the two-phase path is not a micro-optimization,
it is the difference between a ranking and an approximation of one.

### What `dfs=true` refuses to do

A **prefix query** expands against whatever dictionary a shard happens to hold,
so two shards would gather statistics for different term sets and the merge
would mix two rankings. The coordinator detects this (`scoring_terms` returns
None for a prefix) and answers with `"dfs": false` plus
`"dfs_note": "query has shard-dependent terms (prefix); dfs not applied"` rather
than pretending. The same applies to hybrid (`knn`) retrieval, which is not
fanned out at all.

## Failover

Two mechanisms, both measured.

**Replica takeover.** A shard group is `primary|replica|replica`; the coordinator
tries them in order and uses the first that answers. Killing the primary of a
replicated group left the result unchanged — same total, `shards.ok: 3`,
`shards.failed: 0` — because the replica answered with the same data.

**Partial answers.** Killing a shard with no replica dropped the total from 2,376
to 1,562 and reported `ok: 2, failed: 1` with the dead address named. The
coordinator kept serving; the client can see that the answer is partial.

The failure path needed a real fix to get there. `TaskGroup::spawn` defaults to
`allow_failure=false`, where a child task raising cancels the whole group and the
failure propagates into the request handler — so the first version of this took
the *coordinator* down along with the shard. Scatter-gather spawns with
`allow_failure=true`: a shard's failure is data for the merge step.

## What is not implemented

1. **Consistent hashing.** Shard assignment is `hash(id) % shards`; changing the
   shard count moves documents.
2. **No coordinator failover.** One coordinator is a single point of failure.
   Running two would need leader election, which is not here.
3. **No rebalancing.** Moving a shard means re-indexing it.
4. **Aggregations are not distributed.** `facets` and `aggs` are computed locally
   by each node's own `/search`; a coordinator returns them empty rather than
   merging partial counts of unknown completeness. Merging terms aggregations is
   straightforward (sum the counts); merging percentiles or averages needs the
   per-shard raw values, not the summaries.
5. **Writes are not replicated.** The coordinator routes a write to one shard
   group's primary; replicas are not updated, so a replica is only correct if it
   was seeded separately. The failover test seeds the replica directly.
6. **Cross-shard ranking uses local statistics unless asked otherwise**, which is
   the default because it costs one round trip instead of two. The tradeoff is
   measured above rather than hidden.
