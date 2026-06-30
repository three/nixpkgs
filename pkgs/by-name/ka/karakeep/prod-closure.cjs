// Print the production dependency closure of a workspace package, one package
// name per line, computed from a pnpm v9 lockfile (passed as JSON on stdin).
//
// pnpm >= 10 can no longer compute a per-project closure from a hoisted
// install (`pnpm list` reports the whole shared node_modules), so we walk the
// lockfile directly: starting from the target importer's prod/optional
// dependencies, following workspace links into other importers and resolved
// packages into the `snapshots` graph.
const fs = require("fs");
const path = require("path");

const root = process.argv[2] || "apps/workers";
const lock = JSON.parse(fs.readFileSync(0, "utf8"));
const importers = lock.importers || {};
const snapshots = lock.snapshots || {};

const keep = new Set();
const seenSnap = new Set();
const seenImporter = new Set();

function visitImporter(p) {
  if (seenImporter.has(p)) return;
  seenImporter.add(p);
  const imp = importers[p];
  if (!imp) return;
  for (const section of ["dependencies", "optionalDependencies"]) {
    for (const [name, info] of Object.entries(imp[section] || {})) {
      visitDep(name, info.version, p);
    }
  }
}

function visitDep(name, version, base) {
  // Workspace dependency: follow the link into the referenced importer.
  if (typeof version === "string" && version.startsWith("link:")) {
    visitImporter(path.posix.normalize(path.posix.join(base, version.slice(5))));
    return;
  }
  const key = name + "@" + version;
  if (seenSnap.has(key)) return;
  seenSnap.add(key);
  keep.add(name);
  const snap = snapshots[key];
  if (!snap) return;
  for (const section of ["dependencies", "optionalDependencies"]) {
    for (const [depName, depVersion] of Object.entries(snap[section] || {})) {
      visitDep(depName, depVersion, base);
    }
  }
}

visitImporter(root);
console.log([...keep].sort().join("\n"));
