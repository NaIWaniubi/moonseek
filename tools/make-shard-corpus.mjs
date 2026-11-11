#!/usr/bin/env node
// Generate a corpus and split it into shards the way the coordinator would.
//
// The split must use the same hash the coordinator uses (FNV-1a over the id,
// modulo the shard count) or the comparison between cluster and single-node
// results would be measuring a different corpus.
//
// Usage: node tools/make-shard-corpus.mjs [--docs N] [--shards K] [--out DIR]

import fs from "node:fs";
import path from "node:path";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const docs = Number(arg("docs", "3000"));
const shards = Number(arg("shards", "3"));
const outDir = arg("out", "demo/data/shards");

// FNV-1a, byte-wise, exactly as cluster.mbt's shard_for does it.
function shardFor(id, k) {
  let hash = 2166136261 >>> 0;
  for (const ch of Buffer.from(id, "utf8")) {
    hash = (hash ^ (ch & 0xff)) >>> 0;
    hash = (hash * 16777619) >>> 0;
  }
  return hash % k;
}

const nouns = ["parser", "compiler", "runtime", "scheduler", "cache", "codec",
  "router", "tracer", "allocator", "lexer", "vm", "gc", "socket", "timer",
  "matrix", "tensor", "graph", "index", "segment", "wal"];
const adjectives = ["fast", "embedded", "incremental", "concurrent", "zero-copy",
  "streaming", "minimal", "portable", "deterministic", "lock-free"];
const domains = ["moonbit", "wasm", "web", "cli", "database", "graphics",
  "network", "audio", "crypto", "ml"];

// Deterministic RNG so a rerun produces the same corpus and the same shard
// assignment, which is what makes two runs comparable.
let seed = 0x9e3779b9;
function rnd() {
  seed ^= seed << 13; seed >>>= 0;
  seed ^= seed >>> 17;
  seed ^= seed << 5; seed >>>= 0;
  return seed / 4294967296;
}
const pick = (arr) => arr[Math.floor(rnd() * arr.length)];

const buckets = Array.from({ length: shards }, () => []);
let bytes = 0;
for (let i = 0; i < docs; i++) {
  const id = `${pick(domains)}/pkg${i}`;
  const keywords = [pick(nouns), pick(adjectives), pick(domains), pick(nouns)];
  const title = `${keywords[0]} ${pick(adjectives)}`;
  const desc = `A ${pick(adjectives)} ${keywords[0]} library for ${pick(domains)} work in MoonBit.`;
  // The body repeats words so term frequencies vary and BM25 has something to
  // rank: a corpus of unique tokens would make every query equally hard.
  const body = Array.from({ length: 12 + Math.floor(rnd() * 20) },
    () => pick(nouns)).join(" ");
  // The repeated words go into `desc`, the field the schema actually indexes:
  // term-frequency variation has to live in an indexed field or BM25 has
  // nothing to rank and every query becomes equally hard.
  const doc = {
    id,
    fields: {
      title,
      keywords: keywords.join(" "),
      desc: `${desc} ${body}`,
      deps: `moonbitlang/${pick(["async", "x", "parser"])}`,
    },
    facets: { domain: [keywords[2]], license: [pick(["MIT", "Apache-2.0"])] },
    nums: { versions: 1 + Math.floor(rnd() * 30) },
  };
  buckets[shardFor(id, shards)].push(JSON.stringify(doc));
  bytes += JSON.stringify(doc).length;
}

fs.mkdirSync(outDir, { recursive: true });
const counts = [];
for (let k = 0; k < shards; k++) {
  const file = path.join(outDir, `shard-${k}.jsonl`);
  fs.writeFileSync(file, buckets[k].join("\n") + "\n");
  counts.push(buckets[k].length);
}
// A single-node copy of the same corpus, for the equality check.
fs.writeFileSync(
  path.join(outDir, "all.jsonl"),
  buckets.flat().join("\n") + "\n",
);
console.log(
  `${docs} documents (${(bytes / 1024).toFixed(0)} KB) -> ${shards} shards: ${counts.join(" / ")}`,
);
console.log(`single-node copy: ${path.join(outDir, "all.jsonl")}`);
