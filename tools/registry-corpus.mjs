#!/usr/bin/env node
// Build the mooncakes registry corpus used by the demo and the quality bench.
//
// Input: a clone of the mooncakes registry index (one directory per owner,
// one `<pkg>.index` file per package, one JSON object per published version).
// Output: demo/registry.json — one compact record per package, newest version
// only, with the fields the engine indexes plus the facet values.
//
// Usage: node tools/registry-corpus.mjs [--index-dir DIR] [--out FILE]
// The script has no dependencies and never touches the network.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const indexDir = arg("index-dir", path.join(os.homedir(), ".moon", "registry", "index"));
const outFile = arg("out", path.join("demo", "registry.json"));

// Split an identifier into searchable words: snake_case, kebab-case, dots,
// slashes, and camelCase boundaries. "moonbit_doubleML" -> moonbit double ML.
function words(s) {
  return s
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .split(/[^A-Za-z0-9\u3400-\u9fff]+/)
    .filter(Boolean);
}

const userDir = path.join(indexDir, "user");
if (!fs.existsSync(userDir)) {
  console.error(`no registry index at ${userDir}`);
  process.exit(1);
}

const packages = [];
let versionCount = 0;
for (const owner of fs.readdirSync(userDir).sort()) {
  const ownerPath = path.join(userDir, owner);
  if (!fs.statSync(ownerPath).isDirectory()) continue;
  for (const file of fs.readdirSync(ownerPath).sort()) {
    if (!file.endsWith(".index")) continue;
    const lines = fs
      .readFileSync(path.join(ownerPath, file), "utf8")
      .split("\n")
      .filter((l) => l.trim());
    const versions = [];
    for (const line of lines) {
      try {
        versions.push(JSON.parse(line));
      } catch {
        // A malformed line is data damage, not a reason to drop the package.
      }
    }
    if (versions.length === 0) continue;
    versionCount += versions.length;
    const latest = versions[versions.length - 1];
    const first = versions[0];
    const name = latest.name || `${owner}/${file.replace(/\.index$/, "")}`;
    const slash = name.indexOf("/");
    const pkg = slash >= 0 ? name.slice(slash + 1) : name;
    const pkgOwner = slash >= 0 ? name.slice(0, slash) : owner;
    packages.push({
      name,
      pkg,
      owner: pkgOwner,
      title: words(pkg).join(" ") || pkg,
      desc: (latest.description || "").trim(),
      keywords: Array.isArray(latest.keywords) ? latest.keywords.map(String) : [],
      license: latest.license || "",
      deps: latest.deps && typeof latest.deps === "object" ? latest.deps : {},
      repo: latest.repository || "",
      versions: versions.length,
      first: (first.created_at || "").slice(0, 10),
      last: (latest.created_at || "").slice(0, 10),
    });
  }
}

// Facet values, derived once so every consumer agrees on them.
const depCount = new Map();
for (const p of packages) for (const d of Object.keys(p.deps)) depCount.set(d, (depCount.get(d) || 0) + 1);
const topDeps = [...depCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 24).map(([d]) => d);

const records = packages
  .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  .map((p) => {
    const deps = Object.keys(p.deps).sort();
    const facets = [];
    if (p.license) facets.push(["license", [p.license]]);
    const prominent = deps.filter((d) => topDeps.includes(d));
    if (prominent.length) facets.push(["deps", prominent]);
    const year = p.first.slice(0, 4);
    if (year) facets.push(["year", [year]]);
    return {
      // id is the package name: unique, stable, and human-meaningful in results.
      id: p.name,
      title: p.title,
      desc: p.desc,
      keywords: p.keywords,
      deps: deps,
      facets,
      meta: { v: p.versions, lic: p.license, first: p.first, last: p.last, repo: p.repo },
    };
  });

const corpus = {
  generated_from: "mooncakes registry index",
  packages: records.length,
  versions: versionCount,
  top_deps: topDeps,
  docs: records,
};
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(corpus));
const bytes = fs.statSync(outFile).size;
console.log(
  `${records.length} packages (${versionCount} versions) -> ${outFile} (${(bytes / 1024).toFixed(0)} KB)`,
);
const descLens = records.map((r) => r.desc.length).sort((a, b) => a - b);
console.log(
  `descriptions: median ${descLens[descLens.length >> 1]} chars, empty ${descLens.filter((x) => x === 0).length}`,
);
