#!/usr/bin/env node
// Cluster cost and scale-out benchmark.
//
// `tools/test-cluster.sh` proves the cluster answers *correctly*. This asks the
// question correctness cannot: what does a sharded search cost compared to one
// node holding the same corpus, and what does replication cost on the write
// path. The interesting failure mode is not "the cluster is slower" — fan-out
// always adds a hop — it is a coordinator that quietly does K times the work of
// the node it replaces, so every row prints per-shard work alongside the
// end-to-end latency.
//
// Sampling discipline, learned the hard way on this machine: runs are
// interleaved (single, coordinator, single, coordinator, ...) rather than
// batched, because the machine's background load drifts over a run and a
// batched sample compares two different machines. p50 and min are both
// reported: min is the cleanest signal of the cost of the code path, p50 shows
// what a user actually waits for.
//
// Usage: node tools/bench-cluster.mjs <server-binary> [--docs N] [--shards K] [--samples N]

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BIN = process.argv[2];
if (!BIN) {
  console.error("usage: node tools/bench-cluster.mjs <server-binary> [--shards K] [--samples N]");
  process.exit(1);
}
const SHARDS = Number(arg("shards", "3"));
const SAMPLES = Number(arg("samples", "120"));
const ROOT = arg("root", ".");
const SCH = "title:6,keywords:3,desc:1,deps:1.5";

// Server stdout goes to a temp dir, not the repository: a benchmark that writes
// into the tree leaves files nobody asked for and a dirty working copy after
// every run.
const LOG_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "moonseek-bench-"));

const HTTP_BASE = 7861;
const SHARD_PORT_BASE = 7961;
const SINGLE_PORT = 7864;
const COORD_PORT = 7865;

const QUERIES = [
  "parser",
  "compiler AND gc",
  '"zero-copy"',
  "scheduler OR allocator",
  "tensor",
  "socket cache",
];

const children = [];
function shutdown() {
  for (const c of children) {
    try {
      c.kill("SIGKILL");
    } catch {}
  }
}
process.on("exit", shutdown);

function start(args, logName) {
  const out = fs.openSync(path.join(LOG_DIR, `${logName}.log`), "a");
  const c = spawn(BIN, args, { stdio: ["ignore", out, out] });
  children.push(c);
  return c;
}

async function waitReady(port, tries = 120) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(1000) });
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`port ${port} never became ready`);
}

async function post(port, pathname, body) {
  const r = await fetch(`http://127.0.0.1:${port}${pathname}`, {
    method: "POST",
    body,
    headers: { "content-type": "application/json" },
  });
  if (!r.ok) throw new Error(`${pathname} -> ${r.status}: ${await r.text()}`);
  return r.json();
}

async function search(port, q, extra = "") {
  const url = `http://127.0.0.1:${port}/search?q=${encodeURIComponent(q)}&limit=10${extra}`;
  const t0 = performance.now();
  const res = await fetch(url);
  const took = performance.now() - t0;
  const body = await res.json();
  if (body.error) throw new Error(`${port}: ${body.error}`);
  return { took, total: body.total, shards: body.shards || null, serverMs: body.took_ms };
}

const pct = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const min = (xs) => Math.min(...xs);
const fmt = (x) => x.toFixed(2);

async function main() {
  const corpusDir = path.join(ROOT, "demo", "data", "shards");
  if (!fs.existsSync(path.join(corpusDir, "all.jsonl"))) {
    console.error(`missing corpus at ${corpusDir}; run tools/make-shard-corpus.mjs first`);
    process.exit(1);
  }

  console.log(`starting ${SHARDS} shards, one single node, one coordinator`);
  const shardAddrs = [];
  for (let k = 0; k < SHARDS; k++) {
    // One member per group: this benchmark is about fan-out cost, not
    // replication. Write cost of replication is measured separately below with
    // a second member added by hand.
    start(
      [
        "--addr", `127.0.0.1:${HTTP_BASE + k}`,
        "--shard-port", `127.0.0.1:${SHARD_PORT_BASE + k}`,
        "--schema", SCH,
      ],
      `bench-shard-${k}`,
    );
    shardAddrs.push(`127.0.0.1:${SHARD_PORT_BASE + k}`);
  }
  start(["--addr", `127.0.0.1:${SINGLE_PORT}`, "--schema", SCH], "bench-single");
  start(
    ["--addr", `127.0.0.1:${COORD_PORT}`, "--schema", SCH, "--pool", "200", "--shards", shardAddrs.join(",")],
    "bench-coord",
  );

  for (let k = 0; k < SHARDS; k++) await waitReady(HTTP_BASE + k);
  await waitReady(SINGLE_PORT);
  await waitReady(COORD_PORT);

  console.log("loading corpus");
  let docs = 0;
  for (let k = 0; k < SHARDS; k++) {
    const f = path.join(corpusDir, `shard-${k}.jsonl`);
    if (!fs.existsSync(f)) continue;
    const body = fs.readFileSync(f, "utf8");
    docs += body.split("\n").filter(Boolean).length;
    await post(HTTP_BASE + k, "/index/bulk", body);
  }
  await post(SINGLE_PORT, "/index/bulk", fs.readFileSync(path.join(corpusDir, "all.jsonl"), "utf8"));
  console.log(`loaded ${docs} documents`);

  console.log("\n== query cost: interleaved single / coordinator, %d samples each ==", SAMPLES);
  const rows = [];
  for (const q of QUERIES) {
    const single = [];
    const coord = [];
    const perShard = [];
    for (let i = 0; i < SAMPLES; i++) {
      const a = await search(SINGLE_PORT, q);
      single.push(a.took);
      const b = await search(COORD_PORT, q);
      coord.push(b.took);
      if (b.shards) perShard.push(b.shards.total);
    }
    const shardWork = await search(COORD_PORT, q);
    rows.push({
      q,
      singleMin: min(single), singleP50: pct(single, 50),
      coordMin: min(coord), coordP50: pct(coord, 50),
      total: shardWork.total,
      shards: shardWork.shards ? `${shardWork.shards.ok}/${shardWork.shards.total}` : "-",
    });
  }

  console.log("query                          total  shards  single min  single p50  coord min  coord p50  ratio(p50)");
  for (const r of rows) {
    const ratio = r.singleP50 > 0 ? r.coordP50 / r.singleP50 : 0;
    console.log(
      r.q.padEnd(30) +
      String(r.total).padEnd(7) +
      r.shards.padEnd(8) +
      fmt(r.singleMin).padEnd(12) +
      fmt(r.singleP50).padEnd(12) +
      fmt(r.coordMin).padEnd(11) +
      fmt(r.coordP50).padEnd(11) +
      ratio.toFixed(2) + "x",
    );
  }
  const avgRatio = rows.reduce((a, r) => a + r.coordP50 / r.singleP50, 0) / rows.length;
  console.log(`\nmean coordinator/single p50 ratio: ${avgRatio.toFixed(2)}x over ${SHARDS} shards`);
  console.log("(fan-out adds one network hop per shard; a ratio near 1 means the coordinator adds no work of its own)");

  console.log("\n== write cost: replicated coordinator vs single node, %d documents ==", 2000);
  const N = 2000;
  const writeDoc = (i) => JSON.stringify({
    id: `w${i}`,
    fields: { title: `write bench ${i}`, keywords: "writebench", desc: `document ${i}`, deps: "" },
  });

  let t0 = performance.now();
  for (let i = 0; i < N; i++) await post(SINGLE_PORT, "/index", writeDoc(i));
  const singleMs = performance.now() - t0;

  const COORD2 = 7885;
  const REPLICA_HTTP = 7881;
  const REPLICA_SHARD = 7981;
  const replicaShards = [];
  for (let k = 0; k < SHARDS; k++) {
    replicaShards.push(`127.0.0.1:${REPLICA_SHARD + k}`);
    start(
      [
        "--addr", `127.0.0.1:${REPLICA_HTTP + k}`,
        "--shard-port", `127.0.0.1:${REPLICA_SHARD + k}`,
        "--schema", SCH,
      ],
      `bench-replica-${k}`,
    );
  }
  for (let k = 0; k < SHARDS; k++) await waitReady(REPLICA_HTTP + k);

  const grouped = shardAddrs.map((a, k) => `${a}|${replicaShards[k]}`).join(",");
  start(
    ["--addr", `127.0.0.1:${COORD2}`, "--schema", SCH, "--pool", "200", "--shards", grouped],
    "bench-coord-replicated",
  );
  await waitReady(COORD2);

  t0 = performance.now();
  let ackedFull = 0;
  for (let i = 0; i < N; i++) {
    const r = await post(COORD2, "/index", writeDoc(i));
    if (r.ok) ackedFull++;
  }
  const replMs = performance.now() - t0;

  console.log(`single node:            ${fmt(singleMs)} ms for ${N} docs  (${(N / (singleMs / 1000)).toFixed(0)} docs/s)`);
  console.log(`coordinator, 2 members: ${fmt(replMs)} ms for ${N} docs  (${(N / (replMs / 1000)).toFixed(0)} docs/s)`);
  console.log(`cost of replication:    ${(replMs / singleMs).toFixed(2)}x, ${ackedFull}/${N} writes acknowledged by every member`);

  console.log("\n== metadata ==");
  for (let k = 0; k < SHARDS; k++) {
    const s = await (await fetch(`http://127.0.0.1:${HTTP_BASE + k}/_stats`)).json();
    console.log(`shard ${k}: docs=${s.docs} queries=${s.queries}`);
  }
}

main()
  .then(() => {
    shutdown();
    process.exit(0);
  })
  .catch((e) => {
    console.error("BENCH FAILED:", e.message);
    shutdown();
    process.exit(1);
  });
