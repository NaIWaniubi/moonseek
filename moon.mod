// moonseek — embedded full-text search engine in pure MoonBit.
// Docs: https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "cs6210501-lab/moonseek"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/cs6210501-lab/moonseek"

license = "Apache-2.0"

keywords = [ "search", "full-text", "index", "bm25", "chinese", "wasm" ]

preferred_target = "native"

description = "Embedded full-text search engine: inverted index, BM25 ranking, Chinese/English tokenization, crash-safe segments, runs on native/WASM/JS."

import {
  "moonbitlang/async@0.22.4",
}
