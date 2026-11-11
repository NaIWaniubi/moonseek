#!/usr/bin/env node
// Generate a corpus and split it into shards the way the coordinator would.
//
// The split must use the same placement rule the coordinator uses, or the
// comparison between cluster and single-node results would be measuring a
// different corpus, and a document written through the coordinator would land
// on a shard the splitter never put it on.
//
// Two rules, matching `server/cluster.mbt`:
//   * `--mode ring`   (default) consistent hashing with 128 virtual nodes
//   * `--mode modulo` `hash(id) % shards`
//
// The hash is FNV-1a over the UTF-8 bytes, mixed through MurmurHash3's fmix32 —
// exactly `hash_key` in cluster.mbt. Both details matter: hashing the UTF-16
// code units (as an earlier version did) disagrees with this file for
// non-ASCII ids, and plain FNV-1a without the finalizer makes sequential ids
// land in an arithmetic progression, which skews the ring 29/21/50.
//
// Usage: node tools/make-shard-corpus.mjs [--docs N] [--shards K] [--out DIR] [--mode ring|modulo]

import fs from "node:fs";
import path from "node:path";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const docs = Number(arg("docs", "3000"));
const shards = Number(arg("shards", "3"));
const outDir = arg("out", "demo/data/shards");
const mode = arg("mode", "ring");
const RING_VNODES = 128;

// FNV-1a over the UTF-8 bytes, then MurmurHash3's finalizer. Math.imul, not
// `hash * 16777619`: the product of two 32-bit values reaches 7.2e16, past
// Number.MAX_SAFE_INTEGER, so a plain multiply silently rounds and the result
// is not FNV-1a at all.
function fnv1a(text) {
  let hash = 2166136261 >>> 0;
  for (const ch of Buffer.from(text, "utf8")) {
    hash = (hash ^ (ch & 0xff)) >>> 0;
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
}
function fmix32(h) {
  h = (h ^ (h >>> 16)) >>> 0;
  h = Math.imul(h, 0x85ebca6b) >>> 0;
  h = (h ^ (h >>> 13)) >>> 0;
  h = Math.imul(h, 0xc2b2ae35) >>> 0;
  h = (h ^ (h >>> 16)) >>> 0;
  return h;
}
const hashKey = (s) => fmix32(fnv1a(s));

function buildRing(k, vnodes = RING_VNODES) {
  const points = [];
  for (let s = 0; s < k; s++) {
    for (let v = 0; v < vnodes; v++) {
      points.push({ pos: hashKey(`shard:${s}#${v}`), shard: s });
    }
  }
  points.sort((a, b) => (a.pos - b.pos) || (a.shard - b.shard));
  return points;
}

function owner(points, id) {
  const target = hashKey(id);
  let lo = 0, hi = points.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (points[mid].pos < target) lo = mid + 1; else hi = mid;
  }
  return points[lo >= points.length ? 0 : lo].shard;
}

const ring = buildRing(shards);
const place = mode === "modulo"
  ? (id) => hashKey(id) % shards
  : (id) => owner(ring, id);

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
  buckets[place(id)].push(JSON.stringify(doc));
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
// The shard ids, in order, so a test can query /_placement for each of them and
// check the coordinator agrees with the file this tool just wrote. Without
// this, a placement mismatch is invisible: the coordinator queries every shard
// anyway, so a search still finds the document.
const manifest = {
  mode,
  shards,
  vnodes: mode === "ring" ? RING_VNODES : null,
  counts,
  // One id per shard, the first document filed there.
  sample: buckets.map((b) => (b.length ? JSON.parse(b[0]).id : null)),
};
fs.writeFileSync(
  path.join(outDir, "manifest.json"),
  JSON.stringify(manifest, null, 2) + "\n",
);
console.log(
  `${docs} documents (${(bytes / 1024).toFixed(0)} KB) -> ${shards} shards ` +
  `[${mode}]: ${counts.join(" / ")}`,
);
console.log(`single-node copy: ${path.join(outDir, "all.jsonl")}`);
