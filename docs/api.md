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
{ "status": "ok", "version": "0.7.0", "uptime_ms": 12043 }
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
  "clusters": { "shards_total": 4, "shards_ok": 4, "shards_failed": 0 }
}
```

`clusters` is present only when the server is a cluster coordinator.

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

`sort.by` is `score`, `id`, or `num:<field>` (a numeric doc value).

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

## `POST /index/bulk`

Newline-delimited JSON, one document per line, same shape as above. Returns
`{ "indexed": 1000, "took_ms": 41.2 }`. This is the ingest path the benchmarks
use.

## `DELETE /index?id=…`

Tombstones a document. Returns `{ "deleted": true }`.

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
