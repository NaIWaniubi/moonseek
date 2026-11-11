// moonseek — embedded full-text search engine in pure MoonBit.
// Docs: https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "NaIWaniubi/moonseek"

version = "0.9.0"

readme = "README.md"

repository = "https://github.com/NaIWaniubi/moonseek"

license = "Apache-2.0"

keywords = [
  "search",
  "full-text",
  "index",
  "bm25",
  "chinese",
  "wasm",
  "fuzzy",
  "highlight",
  "wal",
  "phrase",
  "wasm-gc",
  "hnsw",
  "vector",
  "distributed",
  "aggregation",
  "consistency",
  "sharding",
  "replication",
]

preferred_target = "native"

description = "Full-text search engine and service: inverted index, BM25, exact and sloppy phrases, dictionary-free Chinese tokenization, fuzzy search, highlighting, facets, numeric aggregations, HNSW vector search with hybrid fusion, an HTTP service, and a distributed cluster with consistent hashing, scatter-gather on global statistics, write replication, failover, and cross-shard aggregations that equal a single node. One snapshot format across native/WASM/JS."

import {
  "moonbitlang/async@0.22.4",
}
