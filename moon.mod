// moonseek — embedded full-text search engine in pure MoonBit.
// Docs: https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "NaIWaniubi/moonseek"

version = "0.6.0"

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
]

preferred_target = "native"

description = "Embedded full-text search engine: inverted index, BM25 ranking, exact and sloppy phrases, dictionary-free Chinese tokenization, fuzzy search (BK-tree), did-you-mean, highlighting, faceted filtering, score explanation, segmented index with WAL crash recovery. One snapshot format across native/WASM/JS."

import {
  "moonbitlang/async@0.22.4",
}
