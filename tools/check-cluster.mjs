#!/usr/bin/env node
// Distributed correctness and scale-out check.
//
// The claim under test: a coordinator querying K shards returns the *same*
// ranking as one node holding the whole corpus, and does so with per-shard work
// proportional to 1/K. The script measures both rather than asserting them,
// because a sharded search that silently ranks differently is the failure mode
// that matters, and it is invisible without a single-node reference.

const SHARDS = [7801, 7802, 7803];
const SINGLE = 7804;
const COORD = 7805;

const DFS = "&dfs=true";

const QUERIES = [
  "parser",
  "compiler AND gc",
  "\"zero-copy\"",
  "scheduler OR allocator",
  "tensor",
  "socket cache",
  "lexer parser graph",
  "minimal matrix",
];

async function search(port, query, extra = "") {
  const url = `http://127.0.0.1:${port}/search?q=${encodeURIComponent(query)}&limit=10${extra}`;
  const t0 = performance.now();
  const res = await fetch(url);
  const took = performance.now() - t0;
  const body = await res.json();
  if (body.error) throw new Error(`${port}: ${body.error}`);
  return {
    ids: body.hits.map((h) => h.id),
    scores: body.hits.map((h) => h.score),
    total: body.total,
    took,
    shards: body.shards || null,
    serverMs: body.took_ms,
  };
}

function sameIds(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

function maxScoreDelta(a, b) {
  if (a.length !== b.length) return NaN;
  let m = 0;
  for (let i = 0; i < a.length; i++) m = Math.max(m, Math.abs(a[i] - b[i]));
  return m;
}

const rows = [];
let idMatches = 0;
let worstDelta = 0;

for (const q of QUERIES) {
  const coord = await search(COORD, q, DFS);
  const single = await search(SINGLE, q);
  const identical = sameIds(coord.ids, single.ids);
  const delta = maxScoreDelta(coord.scores, single.scores);
  if (identical) idMatches++;
  if (Number.isFinite(delta)) worstDelta = Math.max(worstDelta, delta);
  rows.push({ q, identical, delta, coord, single });
}

console.log("query                                  ids==single  max|dScore|  coord ms  single ms  shards");
for (const r of rows) {
  const sh = r.coord.shards
    ? `${r.coord.shards.ok}/${r.coord.shards.total}`
    : "-";
  console.log(
    r.q.padEnd(38) +
      String(r.identical).padEnd(13) +
      (Number.isFinite(r.delta) ? r.delta.toFixed(6) : "n/a").padEnd(12) +
      r.coord.took.toFixed(1).padEnd(10) +
      r.single.took.toFixed(1).padEnd(11) +
      sh,
  );
}
console.log(`\nidentical rankings: ${idMatches}/${QUERIES.length}`);
console.log(`worst per-hit score difference: ${worstDelta.toExponential(3)}`);

// Local-statistics mode is expected to differ; if it did not, the two-phase
// path would be dead code. Report the difference so the docs can be specific.
const localStats = await search(COORD, "parser", "&dfs=false");
console.log(
  `\nlocal-statistics mode, top-3: ${localStats.ids.slice(0, 3).join(", ")}` +
    ` (total ${localStats.total})`,
);
