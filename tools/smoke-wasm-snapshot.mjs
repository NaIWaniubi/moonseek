#!/usr/bin/env node
// Cross-target smoke test: load a native-written snapshot into the wasm build
// and run a query. This is the claim the browser demo rests on, so CI checks it
// on every push rather than trusting a hand-run.
//
// Usage: node tools/smoke-wasm-snapshot.mjs <wasm> <snapshot> [query] [minDocs]

import fs from "node:fs";

const [, , wasmPath, snapshotPath, query = "parser", minDocs = "3600"] = process.argv;
if (!wasmPath || !snapshotPath) {
  console.error("usage: smoke-wasm-snapshot.mjs <wasm> <snapshot> [query] [minDocs]");
  process.exit(2);
}

const wasm = fs.readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(wasm, {}, {
  builtins: ["js-string"],
  importedStringConstants: "_",
});
const api = instance.exports;

const b64 = fs.readFileSync(snapshotPath).toString("base64");
const err = api.ms_load_b64(b64);
if (err) {
  console.error(`snapshot load failed: ${err}`);
  process.exit(1);
}

const docs = api.ms_count();
if (docs < Number(minDocs)) {
  console.error(`only ${docs} documents loaded, expected at least ${minDocs}`);
  process.exit(1);
}

const hits = JSON.parse(api.ms_search(query, 5));
if (!Array.isArray(hits) || hits.length === 0) {
  console.error(`query ${JSON.stringify(query)} returned nothing`);
  process.exit(1);
}

console.log(
  `${docs} documents, ${api.ms_terms()} terms, ` +
    `${JSON.stringify(query)} -> ${hits.map((h) => h.id).slice(0, 3).join(", ")}`,
);
