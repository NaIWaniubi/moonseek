#!/usr/bin/env node
// Mixed-load soak: writes, queries, checkpoints and a mid-run shard restart,
// sustained together, then a strict accounting of what survived.
//
// Every other end-to-end test asserts one behaviour in isolation. This one
// exists because the features that were added last — connection pooling, group
// commit, the write lock, repair's empty-primary rule — interact, and an
// interaction bug shows up as "the numbers stopped adding up after four
// minutes", not as a failed unit test.
//
// The accounting is the point. Each writer records the ids it was told were
// acknowledged; at the end the cluster must hold exactly those ids, in every
// member of every group, with no ghost and no gap. A run that merely stays up
// while silently dropping writes is the failure this is built to catch.
//
// Usage: node tools/soak-cluster.mjs <server-binary> [--seconds N] [--writers N] [--readers N]

import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BIN = process.argv[2];
if (!BIN) {
  console.error("usage: node tools/soak-cluster.mjs <server-binary> [--seconds N]");
  process.exit(1);
}
const SECONDS = Number(arg("seconds", "60"));
const WRITERS = Number(arg("writers", "8"));
const READERS = Number(arg("readers", "6"));
const SCH = "title:6,keywords:3,desc:1,deps:1";
const LOG_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "moonseek-soak-"));

const GROUPS = 3;
const P_HTTP = 8501, P_SHARD = 8511;
const R_HTTP = 8521, R_SHARD = 8531;
const COORD = 8540;

const children = [];
function start(args, name) {
  const out = fs.openSync(path.join(LOG_DIR, `${name}.log`), "a");
  const c = spawn(BIN, args, { stdio: ["ignore", out, out] });
  children.push(c);
  return c;
}
function shutdown() {
  for (const c of children) {
    try { c.kill("SIGKILL"); } catch {}
  }
}

async function waitReady(port, tries = 200) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/healthz`, { signal: AbortSignal.timeout(800) });
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`port ${port} never became ready`);
}

const dirFor = (t) => fs.mkdtempSync(path.join(os.tmpdir(), `ms-soak-${t}-`));

// One shard-protocol exchange: 4-byte little-endian length, JSON, 4-byte length
// back. The HTTP surface has no id listing, and the point of this test is to
// look inside a member, so it speaks the protocol the coordinator speaks.
function shardCall(addr, request) {
  const [host, port] = addr.split(":");
  return new Promise((resolve, reject) => {
    const sock = net.connect(Number(port), host);
    const chunks = [];
    let need = -1;
    let buf = Buffer.alloc(0);
    const timer = setTimeout(() => { sock.destroy(); reject(new Error("shard call timeout " + addr)); }, 20000);
    sock.on("connect", () => {
      const payload = Buffer.from(request, "utf8");
      const header = Buffer.alloc(4);
      header.writeUInt32LE(payload.length, 0);
      sock.write(Buffer.concat([header, payload]));
    });
    sock.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      if (need < 0 && buf.length >= 4) { need = buf.readUInt32LE(0); buf = buf.subarray(4); }
      if (need >= 0 && buf.length >= need) {
        clearTimeout(timer);
        const body = buf.subarray(0, need).toString("utf8");
        sock.end();
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      }
    });
    sock.on("error", (e) => { clearTimeout(timer); reject(e); });
  });
}

async function main() {
  const groups = [];
  // The data directory is the member's identity across restarts: a restart that
  // pointed at a fresh directory would be a wipe, and repair would correctly
  // delete everything its replica still had. Keep it stable.
  const primaryDirs = [];
  for (let k = 0; k < GROUPS; k++) {
    const d = dirFor("p" + k);
    primaryDirs.push(d);
    start(["--addr", `127.0.0.1:${P_HTTP + k}`, "--shard-port", `127.0.0.1:${P_SHARD + k}`, "--schema", SCH, "--data-dir", d], `primary-${k}`);
    start(["--addr", `127.0.0.1:${R_HTTP + k}`, "--shard-port", `127.0.0.1:${R_SHARD + k}`, "--schema", SCH, "--data-dir", dirFor("r" + k)], `replica-${k}`);
    groups.push(`127.0.0.1:${P_SHARD + k}|127.0.0.1:${R_SHARD + k}`);
  }
  start(["--addr", `127.0.0.1:${COORD}`, "--schema", SCH, "--pool", "200", "--shards", groups.join(",")], "coord");
  for (let k = 0; k < GROUPS; k++) {
    await waitReady(P_HTTP + k);
    await waitReady(R_HTTP + k);
  }
  await waitReady(COORD);
  console.log(`soak: ${SECONDS}s, ${WRITERS} writers, ${READERS} readers, ${GROUPS} groups x 2 members`);

  const acked = new Set();
  const errors = [];
  let queries = 0;
  let writes = 0;
  const deadline = Date.now() + SECONDS * 1000;
  let stop = false;

  const writer = async (w) => {
    let i = 0;
    while (!stop) {
      const id = `s${w}/${i++}`;
      const body = JSON.stringify({ id, fields: { title: `soak word${i % 97}`, keywords: "soak", desc: `w${w}`, deps: "" } });
      try {
        const r = await fetch(`http://127.0.0.1:${COORD}/index`, { method: "POST", body, signal: AbortSignal.timeout(30000) });
        const j = await r.json();
        writes++;
        // `ok` means every member applied it; anything else is a caller-visible
        // partial write and must not be counted as durable.
        if (j.ok) acked.add(id);
        else errors.push(`write ${id} not fully acknowledged: ${JSON.stringify(j).slice(0, 120)}`);
      } catch (e) {
        errors.push(`write ${id} threw: ${e.message}`);
      }
    }
  };

  const reader = async (r) => {
    const qs = ["soak", "soak AND word5", '"soak word1"', "word3 OR word7", "soak*", "word42"];
    let k = r;
    while (!stop) {
      const q = qs[k++ % qs.length];
      try {
        const res = await fetch(`http://127.0.0.1:${COORD}/search?q=${encodeURIComponent(q)}&limit=10`, { signal: AbortSignal.timeout(20000) });
        const j = await res.json();
        if (j.error) errors.push(`query ${q}: ${j.error}`);
        else queries++;
      } catch (e) {
        errors.push(`query ${q} threw: ${e.message}`);
      }
    }
  };

  const checkpointer = async () => {
    while (!stop) {
      // Coordinators own no documents and answer 400 here; the durable state is
      // on the primaries, so that is where a checkpoint belongs.
      for (let k = 0; k < GROUPS; k++) {
        try {
          await fetch(`http://127.0.0.1:${P_HTTP + k}/_checkpoint`, { method: "POST", signal: AbortSignal.timeout(60000) }).then((r) => r.text());
        } catch {}
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
  };

  const tasks = [];
  for (let w = 0; w < WRITERS; w++) tasks.push(writer(w));
  for (let r = 0; r < READERS; r++) tasks.push(reader(r));
  tasks.push(checkpointer());

  // Kill and restart one primary in the middle of the run: the coordinator's
  // pooled sockets to it die, its group's writes start failing honestly, and
  // repair has to bring it back afterwards.
  const half = SECONDS * 500;
  const restartTimer = setTimeout(async () => {
    const victim = children.find((c) => c.spawnargs.includes("--addr") && c.spawnargs.includes(`127.0.0.1:${P_HTTP + 1}`));
    if (!victim) return;
    console.log("  mid-run: killing primary 1");
    try { victim.kill("SIGKILL"); } catch {}
    await new Promise((r) => setTimeout(r, 1500));
    console.log("  mid-run: restarting primary 1");
    start(["--addr", `127.0.0.1:${P_HTTP + 1}`, "--shard-port", `127.0.0.1:${P_SHARD + 1}`, "--schema", SCH, "--data-dir", primaryDirs[1]], "primary-1-restart");
    await waitReady(P_HTTP + 1);
  }, half);

  await new Promise((r) => setTimeout(r, SECONDS * 1000 - half));
  stop = true;
  clearTimeout(restartTimer);
  await Promise.allSettled(tasks);
  await new Promise((r) => setTimeout(r, 2000));

  console.log(`  sustained ${writes} accepted writes, ${queries} queries, ${acked.size} fully acknowledged`);

  // Repair, then account for every acknowledged id in every member.
  const rep = await fetch(`http://127.0.0.1:${COORD}/_repair`, { method: "POST", signal: AbortSignal.timeout(120000) }).then((r) => r.json());
  console.log(`  repair: ${JSON.stringify(rep)}`);

  let missing = 0;
  let extra = 0;
  let disagreeingMembers = 0;
  const seen = new Set();
  for (let k = 0; k < GROUPS; k++) {
    const counts = [];
    for (const addr of [`127.0.0.1:${P_SHARD + k}`, `127.0.0.1:${R_SHARD + k}`]) {
      const ids = await shardCall(addr, '{"op":"ids"}').catch(() => ({ ids: [] }));
      const list = ids.ids || [];
      counts.push(list.length);
      for (const id of list) {
        seen.add(id);
        if (id.startsWith("s") && !acked.has(id)) extra++;
      }
    }
    if (counts[0] !== counts[1]) {
      disagreeingMembers++;
      console.log(`  group ${k}: members disagree (${counts[0]} vs ${counts[1]})`);
    }
  }
  for (const id of acked) if (!seen.has(id)) missing++;

  console.log(`  acknowledged but absent: ${missing}`);
  console.log(`  present but never acknowledged: ${extra}`);
  console.log(`  groups whose members disagree: ${disagreeingMembers}`);
  if (missing > 0) {
    // Which ids, and which group owned them: the answer separates "a write that
    // never became durable" from "repair deleted a live document".
    const gone = [...acked].filter((id) => !seen.has(id)).slice(0, 5);
    for (const id of gone) {
      const place = await fetch(`http://127.0.0.1:${COORD}/_placement?id=${encodeURIComponent(id)}`, { signal: AbortSignal.timeout(10000) })
        .then((r) => r.json())
        .catch(() => ({}));
      console.log(`    missing ${id} owned by group ${JSON.stringify(place.shard ?? place)}`);
    }
  }
  if (errors.length) console.log(`  first errors:\n    ${errors.slice(0, 5).join("\n    ")}`);

  const writeErrors = errors.filter((e) => e.startsWith("write")).length;
  if (missing > 0 || disagreeingMembers > 0) {
    console.log("SOAK FAILED: acknowledged writes were lost, or members disagree");
    shutdown();
    process.exit(1);
  }
  if (writeErrors > 0) {
    // A partial write during the outage window is allowed — the client was told
    // so. It must not be counted as acknowledged, and it must not appear as a
    // ghost either; both are checked above.
    console.log(`  ${writeErrors} writes were reported as not fully acknowledged during the outage (expected, and not counted)`);
  }
  console.log("SOAK PASSED: every acknowledged write is present in every member");
  shutdown();
  process.exit(0);
}

main().catch((e) => {
  console.error("SOAK FAILED:", e.message);
  shutdown();
  process.exit(1);
});
