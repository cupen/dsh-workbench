#!/usr/bin/env node
/**
 * Reduce an installed pnpm workspace to what the runtime actually needs.
 *
 * Why not `pnpm prune --prod` / `pnpm install --prod`?
 * - `pnpm prune --prod` drops every workspace link from the root
 *   node_modules, so the built CLI can no longer resolve its workspace
 *   packages.
 * - deepseek-harness declares several packages the compiled code imports at
 *   runtime (e.g. `@deepseek-ai/cordis`, `@anthropic-ai/claude-agent-sdk`)
 *   as devDependencies, so a strict production reinstall produces a broken
 *   runtime image.
 *
 * What we keep:
 *   1. every workspace package and its top-level link (their code lives in
 *      the repo; the links cost nothing);
 *   2. the production dependency closure of every workspace project, walked
 *      through pnpm-lock.yaml;
 *   3. any bare specifier the built JS (lib/dist) imports, matched against
 *      installed packages including platform-suffixed variants;
 *   4. a small documented allowlist of SDKs the built subagents need even
 *      though upstream declares them as devDependencies.
 *
 * Everything else is removed from the pnpm virtual store and the top-level
 * links.
 *
 * Usage: node prune-dev-deps.mjs <repo-root>
 */

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const repo = path.resolve(process.argv[2] ?? process.cwd());
const require_ = createRequire(path.join(repo, "package.json"));
const yaml = require_("js-yaml");

const rootPkg = JSON.parse(
  fs.readFileSync(path.join(repo, "package.json"), "utf8"),
);
const lock = yaml.load(
  fs.readFileSync(path.join(repo, "pnpm-lock.yaml"), "utf8"),
);

// Runtime SDKs declared as devDependencies upstream but required by the
// compiled subagents (claude imports the SDK directly; codex is spawned as a
// binary from its npm package). Kept deliberately; remove only if you accept
// losing those subagent features.
const RUNTIME_ALLOWLIST = [
  "@anthropic-ai/claude-agent-sdk",
  "@openai/codex",
];

// ---- expand workspace globs ("packages/*/*", "vendor/*", ...) ----
function expandGlob(base, glob) {
  const parts = glob.split("/");
  let dirs = [base];
  for (const part of parts) {
    if (part === "*") {
      const next = [];
      for (const d of dirs) {
        let entries = [];
        try {
          entries = fs.readdirSync(d, { withFileTypes: true });
        } catch {
          continue;
        }
        for (const e of entries) {
          if (e.isDirectory()) next.push(path.join(d, e.name));
        }
      }
      dirs = next;
    } else {
      dirs = dirs
        .map((d) => path.join(d, part))
        .filter((d) => {
          try {
            return fs.statSync(d).isDirectory();
          } catch {
            return false;
          }
        });
    }
  }
  return dirs;
}

const wsProjects = [];
for (const g of rootPkg.workspaces ?? []) {
  for (const dir of expandGlob(repo, g)) {
    const pj = path.join(dir, "package.json");
    if (!fs.existsSync(pj)) continue;
    const pkg = JSON.parse(fs.readFileSync(pj, "utf8"));
    if (!pkg.name) continue;
    wsProjects.push({ dir, pkg });
  }
}

// ---- installed virtual-store entries ----
const pnpmDir = path.join(repo, "node_modules", ".pnpm");
const installed = fs
  .readdirSync(pnpmDir, { withFileTypes: true })
  .filter((e) => e.isDirectory())
  .map((e) => e.name);

// '.pnpm' dir name -> { name, version }, e.g.
// '@deepseek-ai+dsh-app-boot@0.1.0-rc.5_@deepseek-ai+cordis@0.1.0-rc.5'
//   -> name '@deepseek-ai/dsh-app-boot'
// '@openai+codex@0.147.0-linux-x64' -> name '@openai/codex'.
function parseDirName(dir) {
  if (dir.startsWith("@")) {
    const at = dir.indexOf("@", 1);
    if (at === -1) return { name: dir, version: "" };
    return { name: dir.slice(0, at).replace("+", "/"), version: dir.slice(at + 1) };
  }
  const at = dir.indexOf("@");
  if (at === -1) return { name: dir, version: "" };
  return { name: dir.slice(0, at), version: dir.slice(at + 1) };
}

const installedByName = new Map();
for (const dir of installed) {
  const { name } = parseDirName(dir);
  if (!installedByName.has(name)) installedByName.set(name, []);
  installedByName.get(name).push(dir);
}

const wsByName = new Map();
for (const p of wsProjects) wsByName.set(p.pkg.name, p);

// Match an import specifier against installed names, including
// platform-suffixed variants (e.g. '@anthropic-ai/claude-agent-sdk-linux-x64').
function matchInstalledNames(spec) {
  const out = [];
  for (const [name, dirs] of installedByName) {
    if (name === spec || name.startsWith(`${spec}-`)) out.push(...dirs);
  }
  return out;
}

// ---- bare specifiers imported by built JS ----
function scanBuiltImports() {
  const names = new Set();
  const re =
    /(?:from\s*|import\s*\(\s*|require\s*\(\s*)(['"])([^'"]+)\1/g;
  const roots = ["packages", "apps", "vendor", "website", "native"];
  const walk = (dir) => {
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name === "node_modules" || e.name === ".git") continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        walk(full);
      } else if (
        /\.(?:js|mjs|cjs)$/.test(e.name) &&
        /(^|\/)(lib|dist)\//.test(full.replaceAll("\\", "/"))
      ) {
        let text = "";
        try {
          text = fs.readFileSync(full, "utf8");
        } catch {
          continue;
        }
        for (const m of text.matchAll(re)) {
          const spec = m[2];
          if (spec.startsWith(".") || spec.startsWith("/") || spec.startsWith("node:")) {
            continue;
          }
          const noQuery = spec.split(/[?#]/)[0];
          const parts = noQuery.split("/");
          const name = noQuery.startsWith("@")
            ? `${parts[0]}/${parts[1]}`
            : parts[0];
          if (name) names.add(name);
        }
      }
    }
  };
  for (const r of roots) walk(path.join(repo, r));
  return names;
}

// ---- BFS over the production closure ----
const snapshots = lock.snapshots ?? lock.packages ?? {};

// Lockfile keys look like 'name@version(peer@ver)(peer2@ver)' while the
// virtual-store dir names use 'name@version_peer+name@ver'. Build a map from
// the base 'name@baseVersion' to a lockfile key so installed dirs can be
// looked up.
const lockKeyByBase = new Map();
for (const key of Object.keys(snapshots)) {
  const at = key.startsWith("@") ? key.indexOf("@", 1) : key.indexOf("@");
  if (at === -1) continue;
  const name = key.slice(0, at);
  let base = key.slice(at + 1);
  const paren = base.indexOf("(");
  if (paren !== -1) base = base.slice(0, paren);
  const mapKey = `${name}@${base}`;
  if (!lockKeyByBase.has(mapKey)) lockKeyByBase.set(mapKey, key);
}

function lockEntryForDir(dir) {
  const { name, version } = parseDirName(dir);
  let base = version.split("_")[0];
  if (version.includes("_patch_hash=")) base = version;
  return snapshots[lockKeyByBase.get(`${name}@${base}`)];
}

const kept = new Set(); // installed .pnpm dir names to keep
const seenWs = new Set();
const queue = [];

// 1. Every workspace package is kept (own files + top-level link).
for (const dir of installed) {
  const { name } = parseDirName(dir);
  if (wsByName.has(name)) kept.add(dir);
}

// 2. Seed with the production deps of every workspace project.
for (const p of wsProjects) {
  const deps = {
    ...(p.pkg.dependencies ?? {}),
    ...(p.pkg.optionalDependencies ?? {}),
    ...(p.pkg.peerDependencies ?? {}),
  };
  for (const name of Object.keys(deps)) enqueueName(name);
}

// 3. Built JS may import devDependencies at runtime; keep those too.
for (const name of scanBuiltImports()) enqueueName(name);

// 4. Documented runtime allowlist.
for (const name of RUNTIME_ALLOWLIST) enqueueName(name);

function enqueueName(name) {
  if (wsByName.has(name)) {
    queue.push({ kind: "ws", name });
    return;
  }
  for (const dir of matchInstalledNames(name)) {
    queue.push({ kind: "pkg", dir });
  }
}

while (queue.length) {
  const node = queue.shift();
  if (node.kind === "ws") {
    if (seenWs.has(node.name)) continue;
    seenWs.add(node.name);
    const p = wsByName.get(node.name);
    const deps = {
      ...(p.pkg.dependencies ?? {}),
      ...(p.pkg.optionalDependencies ?? {}),
      ...(p.pkg.peerDependencies ?? {}),
    };
    for (const name of Object.keys(deps)) enqueueName(name);
    continue;
  }
  if (kept.has(node.dir)) continue;
  kept.add(node.dir);
  const entry = lockEntryForDir(node.dir);
  if (!entry) continue;
  const deps = {
    ...(entry.dependencies ?? {}),
    ...(entry.optionalDependencies ?? {}),
    ...(entry.peerDependencies ?? {}),
  };
  for (const name of Object.keys(deps)) enqueueName(name);
}

// ---- delete what is not kept ----
let removedBytes = 0;
const removedDirs = [];
for (const dir of installed) {
  // The virtual store's own node_modules holds pnpm's hoisted links (including
  // workspace plugins that loader entries import by name); never delete it.
  if (dir === "node_modules") continue;
  if (kept.has(dir)) continue;
  const target = path.join(pnpmDir, dir);
  let size = 0;
  try {
    const st = fs.statSync(target);
    size = st.size;
  } catch {
    /* already gone */
  }
  fs.rmSync(target, { recursive: true, force: true });
  removedDirs.push(dir);
  removedBytes += size;
}

// Drop top-level symlinks pointing into removed virtual-store dirs, but never
// touch links that belong to workspace packages.
function cleanLinks(dir) {
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isSymbolicLink()) {
      const linkName =
        dir === path.join(repo, "node_modules")
          ? e.name
          : `${path.basename(dir)}/${e.name}`;
      if (wsByName.has(linkName)) continue;
      const target = fs.readlinkSync(full);
      const resolved = path.resolve(dir, target);
      const m = resolved.match(/[\\/]\.pnpm[\\/]([^\\/]+)(?:[\\/]|$)/);
      if (m && !kept.has(m[1])) {
        fs.unlinkSync(full);
      }
    } else if (e.isDirectory()) {
      cleanLinks(full);
    }
  }
}
cleanLinks(path.join(repo, "node_modules"));

// Remove now-dangling .bin symlinks.
const binDir = path.join(repo, "node_modules", ".bin");
try {
  for (const e of fs.readdirSync(binDir)) {
    const full = path.join(binDir, e);
    try {
      if (!fs.existsSync(full)) fs.unlinkSync(full);
    } catch {
      /* ignore */
    }
  }
} catch {
  /* no .bin dir */
}

// Remove dangling links inside the virtual store's hoisted node_modules
// (links to pruned dev-only packages are gone; workspace links must stay).
const hoistedDir = path.join(pnpmDir, "node_modules");
try {
  const walkHoisted = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isSymbolicLink()) {
        const target = fs.readlinkSync(full);
        try {
          if (!fs.existsSync(path.resolve(dir, target))) fs.unlinkSync(full);
        } catch {
          /* ignore */
        }
      } else if (e.isDirectory()) {
        walkHoisted(full);
      }
    }
  };
  walkHoisted(hoistedDir);
} catch {
  /* no hoisted dir */
}

console.log(
  `[prune-dev-deps] kept ${kept.size}/${installed.length} packages, ` +
    `removed ${removedDirs.length} (${(removedBytes / 1024 / 1024).toFixed(0)} MiB of files)`,
);
