#!/usr/bin/env node
// Cross-language golden vectors for shard placement.
//
// The coordinator (MoonBit, server/cluster.mbt) and the offline splitter
// (tools/make-shard-corpus.mjs) must agree on which shard owns a document, or
// the "cluster equals a single node" test would be comparing two different
// corpora and would pass while being meaningless.
//
// This prints the vectors; a copy of them lives in server/cluster_wbtest.mbt as
// a test. Run this after changing any hash and paste the result there, so the
// two implementations are pinned to each other by data rather than by a
// comment claiming they match.
//
// Usage: node tools/shard-hash-vector.mjs

const RING_VNODES = 128;

function fnv1a(text) {
  let hash = 2166136261 >>> 0;
  for (const b of Buffer.from(text, "utf8")) {
    hash = (hash ^ (b & 0xff)) >>> 0;
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

// Placement uses the finalized hash, exactly as cluster.mbt's hash_key does.
const hashKey = (s) => fmix32(fnv1a(s));

function buildRing(shards, vnodes = RING_VNODES) {
  const points = [];
  for (let s = 0; s < shards; s++) {
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

const IDS = [
  "a",
  "pkg/one",
  "moonbitlang/async",
  "web/pkg0",
  "cli/pkg1",
  "搜索引擎/包",
  "中文分词器",
  "z9",
];

const ring3 = buildRing(3);
const ring4 = buildRing(4);

console.log("// id | fnv1a | hash_key | modulo(3) | ring(3) | ring(4)");
for (const id of IDS) {
  console.log(
    JSON.stringify([
      id,
      fnv1a(id),
      hashKey(id),
      hashKey(id) % 3,
      owner(ring3, id),
      owner(ring4, id),
    ]),
  );
}

// The reshuffle numbers the docs quote, over 20,000 synthetic ids.
const ids = [];
for (let i = 0; i < 20000; i++) ids.push(`pkg/${i}`);
const modMoved = ids.filter((x) => (hashKey(x) % 3) !== (hashKey(x) % 4)).length;
const ringMoved = ids.filter((x) => owner(ring3, x) !== owner(ring4, x)).length;
console.log(
  `// 3 -> 4 shards over 20000 ids: modulo moved ${(100 * modMoved / ids.length).toFixed(1)}%, ` +
  `ring moved ${(100 * ringMoved / ids.length).toFixed(1)}% (ideal 25%)`,
);

const counts = [0, 0, 0];
for (const x of ids) counts[owner(ring3, x)]++;
console.log(`// ring balance over 3 shards: ${counts.join(" / ")} (ideal 6667 each)`);
