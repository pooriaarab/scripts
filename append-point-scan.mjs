#!/usr/bin/env node
// append-point-scan — flag shared append points from repo contents alone.
//
// A shared append point is one file (often one line) that every unit of work
// must edit. It costs nothing while one agent works, and serializes the whole
// repo the moment several do. Churn alone does not prove harm; these patterns
// predict it. Ported from the validated append-point-scan.py reference.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const CACHE_DIR = process.env.HOTSPOT_CACHE ?? '/tmp/hotspot/cache';
const CHECK_RE = /--check\b|--frozen|--verify\b/;
const GEN_RE = /gen(erate)?$|build$|write$/;
const INLINE_GEN_RE = /(\S+(?:generate|inventory|surface|schema)\S*)/;

export function git(repo, ...args) {
  try {
    return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  } catch {
    return '';
  }
}

export function resolveRef(repo) {
  for (const c of ['origin/main', 'origin/master', 'HEAD']) {
    if (git(repo, 'rev-parse', '--verify', '-q', c).trim()) return c;
  }
  return 'HEAD';
}

// Root package.json first. git ls-tree sorts apps/ and integrations/ before
// the root file, so a naive head-N cap drops the one holding the ci script.
export function pkgJsons(files) {
  return files
    .filter((f) => path.basename(f) === 'package.json' && !f.includes('node_modules'))
    .sort((a, b) => a.split('/').length - b.split('/').length || (a < b ? -1 : 1))
    .slice(0, 25);
}

export function readScripts(repo, ref, pj) {
  try {
    return JSON.parse(git(repo, 'show', `${ref}:${pj}`)).scripts ?? {};
  } catch {
    return {};
  }
}

function stem(name) {
  const i = name.lastIndexOf(':');
  return i === -1 ? name : name.slice(0, i);
}

// bun/npm/pnpm run <script>. Strip quotes; skip flags like --silent.
function scriptEdges(value) {
  if (typeof value !== 'string') return [];
  const names = [];
  for (const m of value.matchAll(/\b(?:bun|npm|pnpm)\s+run\s+([^\s&|;]+)/g)) {
    const n = m[1].replace(/^['"]+|['"]+$/g, '');
    if (n && !n.startsWith('-')) names.push(n);
  }
  return names;
}

function isPullRequestWorkflow(text) {
  const cut = text.search(/^jobs\s*:/m);
  const head = cut === -1 ? text : text.slice(0, cut);
  return /\bpull_request\b/.test(head);
}

// Prefer the ci script. If the repo has none, take bun/npm/pnpm run
// names from pull_request workflows. found is false when both miss.
function prEntrypoints(repo, ref, files, rootScripts) {
  if (typeof rootScripts.ci === 'string') {
    return { names: ['ci'], found: true };
  }
  const names = [];
  const seen = new Set();
  for (const f of files) {
    if (!/^\.github\/workflows\/[^/]+\.ya?ml$/.test(f)) continue;
    const text = git(repo, 'show', `${ref}:${f}`);
    if (!isPullRequestWorkflow(text)) continue;
    for (const n of scriptEdges(text)) {
      if (seen.has(n)) continue;
      seen.add(n);
      names.push(n);
    }
  }
  return { names, found: names.length > 0 };
}

// BFS. parent.has(name) is the visited set, so a cycle cannot re-queue.
function reachableFrom(scripts, entrypoints) {
  const parent = new Map();
  const queue = [];
  for (const e of entrypoints) {
    if (typeof scripts[e] !== 'string' || parent.has(e)) continue;
    parent.set(e, null);
    queue.push(e);
  }
  while (queue.length > 0) {
    const cur = queue.shift();
    for (const nxt of scriptEdges(scripts[cur])) {
      if (typeof scripts[nxt] !== 'string' || parent.has(nxt)) continue;
      parent.set(nxt, cur);
      queue.push(nxt);
    }
  }
  return parent;
}

function pathFrom(parent, name) {
  const parts = [name];
  const seen = new Set([name]);
  let cur = parent.get(name);
  while (cur != null && !seen.has(cur)) {
    seen.add(cur);
    parts.unshift(cur);
    cur = parent.get(cur);
  }
  return parts.join(' -> ');
}

export function scanRepo(repo) {
  const ref = resolveRef(repo);
  const files = git(repo, 'ls-tree', '-r', '--name-only', ref).split('\n').filter(Boolean);
  const hits = [];
  const pjs = pkgJsons(files);

  for (const pj of pjs) {
    const scripts = readScripts(repo, ref, pj);
    for (const [k, v] of Object.entries(scripts)) {
      if (typeof v === 'string' && v.length > 400) {
        hits.push({ kind: 'ENUMERATED-SCRIPT', where: `${pj} :: ${k}`, detail: `${v.length} chars, ${v.split(' && ').length} segments` });
      }
    }
  }

  // A --check is a freshness gate only when the same package declares a
  // sibling that generates what is checked AND a PR-path script reaches
  // it. format:check (prettier) has no format:generate sibling, so it is
  // a linter, not a gate. A main-only round-trip --check is not a PR gate.
  const rootScripts = pjs.length > 0 ? readScripts(repo, ref, pjs[0]) : {};
  const { names: entrypoints, found: foundEntrypoint } = prEntrypoints(repo, ref, files, rootScripts);
  const unclassified = [];
  for (const pj of pjs) {
    const scripts = readScripts(repo, ref, pj);
    const names = Object.keys(scripts);
    const parent = reachableFrom(scripts, entrypoints);
    for (const [k, v] of Object.entries(scripts)) {
      if (typeof v !== 'string' || !CHECK_RE.test(v)) continue;
      const s = stem(k);
      const siblings = names.filter((n) => n !== k && stem(n) === s && GEN_RE.test(n));
      const inline = v.match(INLINE_GEN_RE);
      if (!(siblings.length > 0 || (inline && s !== 'format'))) continue;
      if (!foundEntrypoint) {
        unclassified.push(`${pj} :: ${k}`);
        continue;
      }
      if (!parent.has(k)) continue;
      hits.push({
        kind: 'FRESHNESS-GATE',
        where: `${pj} :: ${pathFrom(parent, k)}`,
        detail: `paired generator: ${siblings.length > 0 ? siblings.join(', ') : inline[1]}`,
      });
    }
  }
  if (unclassified.length > 0) {
    hits.push({
      kind: 'FRESHNESS-GATE',
      where: 'no PR entrypoint',
      detail: `no ci script and no pull_request workflow run; left unchecked: ${unclassified.join(', ')}`,
    });
  }

  const ord = files.filter((f) => f.endsWith('_journal.json') || f.includes('migrations/meta'));
  if (ord.length > 0) hits.push({ kind: 'ORDINAL-REGISTRY', where: `${ord.length} files`, detail: ord.slice(0, 3).join(', ') });
  const junk = files.filter((f) => f.endsWith('.log') || f.endsWith('.tsbuildinfo'));
  if (junk.length > 0) hits.push({ kind: 'COMMITTED-JUNK', where: `${junk.length} files`, detail: junk.slice(0, 4).join(', ') });
  return hits;
}

// A local directory is used as-is; owner/repo is cloned to a shared cache.
export function resolveTarget(target) {
  if (fs.existsSync(target) && fs.statSync(target).isDirectory()) return { dir: target, name: target };
  if (/^[\w.-]+\/[\w.-]+$/.test(target)) {
    const d = `${CACHE_DIR}/${target.replace('/', '_')}`;
    if (!fs.existsSync(d)) {
      try {
        execFileSync('git', ['clone', '--filter=blob:none', '--bare', '--quiet', `https://github.com/${target}.git`, d], { stdio: 'ignore' });
      } catch {
        return { skip: `SKIP ${target} (clone failed)` };
      }
    }
    return { dir: d, name: target };
  }
  return { error: `unknown target: ${target} (want a local dir or owner/repo)` };
}

export async function main(argv) {
  if (argv.includes('--help') || argv.includes('-h') || argv.length === 0) {
    process.stdout.write('Usage: append-point-scan <local-dir|owner/repo> [...]\n');
    return argv.length === 0 ? 2 : 0;
  }
  for (const target of argv) {
    const r = resolveTarget(target);
    if (r.error) {
      process.stderr.write(`${r.error}\n`);
      return 2;
    }
    if (r.skip) {
      process.stdout.write(`${r.skip}\n`);
      continue;
    }
    const hits = scanRepo(r.dir);
    if (hits.length > 0) {
      process.stdout.write(`=== ${r.name} ===\n`);
      for (const h of hits) process.stdout.write(`  [${h.kind}] ${h.where}\n      ${h.detail}\n`);
      process.stdout.write('\n');
    }
  }
  return 0;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main(process.argv.slice(2)).then((c) => { process.exitCode = c; }).catch((e) => { process.stderr.write(`${e.stack || e}\n`); process.exitCode = 1; });
}
