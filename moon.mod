// moonseek — embedded full-text search engine in pure MoonBit.
// Docs: https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "NaIWaniubi/moonseek"

version = "0.7.1"

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
]

preferred_target = "native"

description = "Full-text search engine and service: inverted index, BM25, exact and sloppy phrases, dictionary-free Chinese tokenization, fuzzy search, highlighting, facets, numeric aggregations, HNSW vector search with hybrid fusion, an HTTP service, and a distributed coordinator with scatter-gather, global statistics and failover. One snapshot format across native/WASM/JS."

import {
  "moonbitlang/async@0.22.4",
}
