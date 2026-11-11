# moonseek-server HTTP API

The REST surface of the search service. The console, the cluster coordinator and
the benchmarks all speak exactly this; it is frozen before the parallel build so
that components can be developed against it independently.

Base URL: `http://127.0.0.1:7700` by default (`--addr host:port`).

All responses are `application/json; charset=utf-8`. All endpoints allow CORS
(`Access-Control-Allow-Origin: *`) so the console can be served from anywhere.

Errors always use the same shape, so a client never has to guess:

```json
{ "error": "unknown field: titel", "code": "bad_request" }
```

`code` is one of `bad_request` (400), `not_found` (404), `too_many_requests` (429),
`internal` (500).

---

## `GET /healthz`

Liveness. Never touches the index.

```json
{ "status": "ok", "version": "0.8.0", "uptime_ms": 12043 }
```

## `GET /_stats`

Index and process statistics. Cheap enough to poll once a second.

```json
{
  "docs": 3698,
  "terms": 11081,
  "fields": ["title", "keywords", "desc", "deps"],
  "snapshot_bytes": 1398936,
  "segments": 1,
  "queries_served": 4211,
  "indexed_docs": 3698,
  "deleted_docs": 0,
  "avg_query_ms": 0.42,
  "p99_query_ms": 2.10,
  "memory_bytes": 4194304
}
```

## `GET /_ring`

Placement introspection: which rule the process is using and how the ring's
points divide across shards. Either role answers it; on a single node the ring
is empty because there is nothing to place.

```json
{
  "role": "coordinator",
  "shards": 3,
  "mode": "ring",
  "vnodes": 128,
  "ring_points": 384,
  "points_per_shard": [128, 128, 128],
  "groups": [
    { "primary": "127.0.0.1:7901", "points": 128 },
    { "primary": "127.0.0.1:7902", "points": 128 },
    { "primary": "127.0.0.1:7903", "points": 128 }
  ]
}
```

Point counts are not document counts, but a shard holding most of the points is
the first sign of a skewed hash.

## `GET /_placement?id=…`

Which shard group owns one document id. The client-visible half of the placement
rule — a client can compute the same answer itself, which is how the two are
checked against each other rather than assumed to agree.

```json
{
  "id": "cli/pkg1",
  "shard": 0,
  "mode": "ring",
  "local": false,
  "primary": "127.0.0.1:7901"
}
```

`local: true` (and no `primary`) means this process is not a coordinator, so it
owns the document itself.

## `GET /_plan?shards=N`

A rebalancing plan: how many documents would move if the cluster had `N` shard
groups, under both placement rules, computed from the **real** document ids
gathered from the shards rather than from a sample.

```json
{
  "ids": 3000,
  "from_shards": 3,
  "to_shards": 4,
  "active_mode": "ring",
  "ring":   { "moved": 762,  "total": 3000, "moved_pct": 25.4,
              "before": [969, 1024, 1007], "after": [840, 738, 660, 762] },
  "modulo": { "moved": 2273, "total": 3000, "moved_pct": 75.8,
              "before": [1022, 987, 991], "after": [786, 726, 748, 740] }
}
```

`active_mode` says which of the two numbers is in force. If a shard did not
answer, its ids are missing and the shard is named in `failed_addresses`, so a
plan built on part of the corpus says so.

## `POST /_rebalance?from=N`

**Coordinator only.** Move every document the ring's new owner assigns elsewhere,
so the cluster can grow without a reindex.

`from` is the shard count the data is currently placed by. The operator adds the
new group to `--shards` and restarts the coordinator first, so the process cannot
infer it from its own configuration — which is why the parameter is required and
why a request without it is a `400`.

```json
{ "op": "rebalance", "ok": true, "moved": 762, "replicated": 6,
  "deferred": 0, "missing_at_source": 0, "shards": 4 }
```

| field | meaning |
|---|---|
| `moved` | documents written to their new owner |
| `replicated` | member-level writes and deletes that were acknowledged |
| `deferred` | ids whose destination did not fully acknowledge, so they were **left in place** |
| `missing_at_source` | ids a source shard no longer had; a healthy cluster reports `0` |
| `ok` | nothing failed. `ok` is not "something moved" — a rebalance that needed no moves reports `ok: true` with `moved: 0` |

**The order of operations is the guarantee**: write to the destination, wait for
every member of that group to acknowledge, and only then remove from the source.
A document that exists twice is recoverable by re-running; a document deleted
from its source before its destination had it is gone. Anything not fully
acknowledged is counted in `deferred` and left alone.

Documents come across in the same JSON `POST /index` accepts, vectors included,
so a moved document is not a special case with its own bugs. Re-running a
completed rebalance is a no-op.

## `POST /_repair`

**Coordinator only.** Anti-entropy: bring every member of every group back in line
with its group's **primary**, which is authoritative. Run it after a member comes
back, and after any window in which a write may have been acknowledged by only
some members.

```json
{ "op": "repair", "ok": true, "moved": 1007, "replicated": 1,
  "deferred": 0, "missing_at_source": 0, "shards": 3 }
```

For a repair, `moved` counts documents copied to a member that lacked them and
`deferred` counts documents *removed* from a member its primary did not have.
Both directions matter: a replica that answers with extra documents reports a
different total from its primary, which is exactly the state failover must not be
in. Only the primary's ids travel as a `has` query, so the request size is bounded
by that group's share of the corpus rather than the whole one.

## `GET /search`

| param | default | meaning |
|---|---|---|
| `q` | (required) | query string; full syntax below |
| `limit` | 10 | max hits, 0 = all (capped by `MAX_LIMIT` 1000) |
| `offset` | 0 | pagination offset |
| `facets` | — | comma-separated facet fields to aggregate |
| `filter` | — | `field:value` repeated, e.g. `filter=license:MIT&filter=year:2026` (OR within a field, AND across) |
| `highlight` | `body` | field to produce a snippet for |
| `snippet_chars` | 160 | snippet length |
| `explain` | `false` | include the per-term BM25 breakdown per hit |
| `knn` | — | vector query: `field:k1,k2,...` (comma-separated floats) |
| `knn_k` | 100 | how many neighbours the vector index contributes |
| `fusion` | `rrf` | `rrf` or `weighted` |
| `alpha` | 0.5 | weight for BM25 in `weighted` fusion |
| `sort` | `score` | `score`, `id`, or `num:<field>` (a numeric doc value) |
| `order` | per `sort` | `asc` or `desc`; see below |

Response:

```json
{
  "query": "parser",
  "total": 400,
  "took_ms": 0.83,
  "hits": [
    {
      "id": "moonbitlang/parser",
      "score": 42.3279,
      "fields": { "title": "parser", "keywords": "parser lexer AST MoonBit" },
      "snippet": "…<mark>parser</mark>…",
      "explain": [
        { "field": "title", "term": "parser", "tf": 1, "df": 30, "idf": 4.80, "norm": 0.91, "score": 33.51 }
      ]
    }
  ],
  "facets": {
    "license": [["Apache-2.0", 292], ["MIT", 94]],
    "deps": [["moonbitlang/async", 938]]
  },
  "suggest": "parser",
  "aggs": [
    { "field": "license", "kind": "terms",
      "buckets": [["Apache-2.0", 292], ["MIT", 94]] },
    { "field": "versions", "kind": "stats",
      "stats": { "count": 3698, "min": 1, "max": 52, "avg": 2.41, "sum": 8912 } },
    { "field": "year", "kind": "histogram",
      "buckets": [["2024", 10], ["2025", 213], ["2026", 3475]] },
    { "field": "versions", "kind": "percentiles",
      "percentiles": [[50, 1], [90, 5], [99, 21]] }
  ],
  "shards": { "total": 4, "ok": 4, "failed": 0, "failed_addresses": [] }
}
```

`shards` is present only when the server is a cluster coordinator. On a
coordinator `facets` and `aggs` are merged across shards and equal what a single
node holding the whole corpus would return; `agg_failed_addresses` appears when a
shard answered the search but not the aggregation, because a facet total from
two of three shards is a smaller number presented as a count of the corpus.

`facets` and `aggs` are different things and both are always present when
requested. `facets` is the cheap path: for each requested field, the counts of
its facet values over the filtered result set. `aggs` is the general path: each
entry is one `AggSpec` result, and `kind` says which of `buckets` / `stats` /
`percentiles` is meaningful (`terms` and `histogram` fill `buckets`, `stats`
fills `stats`, `percentiles` fills `percentiles`; the others are absent rather
than null). Bucket keys are labels: a histogram key is the bucket's inclusive
lower edge (`"2025"` means `[2025, 2026)`).

## `POST /search`

The same request as JSON, for queries too long or too structured for a query
string. Body:

```json
{
  "query": "\"database index\"~3 AND license:MIT",
  "limit": 20,
  "facets": ["license", "year"],
  "filters": [ { "field": "license", "values": ["MIT", "Apache-2.0"] } ],
  "aggs": [
    { "type": "stats", "field": "versions" },
    { "type": "histogram", "field": "year", "interval": 1 },
    { "type": "terms", "field": "license", "size": 10 }
  ],
  "sort": { "by": "score", "order": "desc" },
  "knn": { "vector": [0.1, 0.2, 0.3], "k": 100, "field": "emb" }
}
```

`sort.by` is `score`, `id`, or `num:<field>` (a numeric doc value). The
response echoes the order that was applied, as `"sort"` and `"order"`.

**Defaults.** `order` defaults per `sort`: `score` and `num:` descend (a "top N"
is nearly always the largest), `id` ascends (a listing is nearly always A to Z).
Overriding it is always allowed.

**An unrecognized sort is a `400`**, not a silent fall back to score order. The
parameter is documented, so accepting it and ignoring it would be worse than
refusing it.

**Documents with no value for the field sort last in both directions.** A missing
value is not a small number: treating it as zero would file every undated
document between the oldest and the newest, which looks like data rather than a
bug. For a numeric sort each hit also carries its `sort_key`, and a value-less
hit omits it.

**On a coordinator**, each shard returns its own top-`pool` *under the requested
order*, so the merge yields the global top `limit`. The shards ship the numeric
key, because a coordinator that merged on ids while claiming to sort by a field
would return the same set in an order that merely looks plausible. A sort by
`id` or by a numeric field is exact in the default (local statistics) mode,
since it never reads a score; a `score` sort is exact only with `dfs=true`, for
the reason [docs/cluster.md](cluster.md) measures.

## `POST /index`

Add or replace one document. `202` on success.

```json
{
  "id": "pkg/name",
  "fields": { "title": "name", "keywords": "a b", "desc": "…", "deps": "x/y" },
  "facets": { "license": ["MIT"], "year": ["2026"] },
  "nums": { "versions": 5 }
}
```

On a **coordinator** the document is routed to the group that owns its id and
sent to every member of that group. The reply says how many members applied it:

```json
{ "ok": true, "id": "pkg/name", "shard": 2, "acked": 3, "members": 3,
  "primary": "127.0.0.1:7903" }
```

`ok` means **every** member applied it. A write acknowledged by one member of
three is not durable and is not reported as a success: those replies carry
`"ok": false`, the counts, and the addresses that missed it in
`failed_addresses`.

## `POST /index/bulk`

Newline-delimited JSON, one document per line, same shape as above. Returns
`{ "indexed": 1000, "took_ms": 41.2 }`. This is the ingest path the benchmarks
use.

On a **coordinator** the batch is grouped by owning shard and each shard group
receives one request carrying only the documents it owns — one round trip per
shard rather than per document. A batch forwarded whole would have every shard
index every document, and then several shards would answer for the same
document. The reply adds `shards`, `members_ok` and `members`:

```json
{ "indexed": 3000, "failed": 0, "shards": 3, "members_ok": 6, "members": 6,
  "took_ms": 152 }
```

## `DELETE /index?id=…`

Tombstones a document. Returns `{ "deleted": true }`.

On a coordinator the delete is routed to the owning group and replicated the
same way, so it does not report a deletion that only happened somewhere the
search will not look.

## `GET /suggest?q=…`

Did-you-mean. `{ "suggestion": "parser", "fuzzy": [["parser", 0]] }`.

## `GET /explain?id=…&q=…`

`{ "id": "…", "total_score": 42.3, "details": [ … ] }`, or `null`.

## `GET /terms?field=…&limit=…`

Term dictionary with document frequencies, most frequent first:
`{ "terms": [["parser", 232]] }`.

---

## Query syntax

| form | meaning |
|---|---|
| `term` | full-text match |
| `"a b"` | exact phrase (positional) |
| `"a b"~3` | sloppy phrase: up to 3 tokens between neighbours, order kept |
| `A AND B` / `A OR B` | boolean; juxtaposition is implicit AND |
| `A NOT B` | exclude |
| `field:term` / `field:"a b"~2` | restrict to a field |
| `pre*` | prefix (dictionary-order expansion) |
| `(A OR B) C` | grouping |

CJK text is indexed as overlapping bigrams, so `搜索引擎` is searchable with no
dictionary.
