#!/usr/bin/env node
// merge-hotspots — rank files by share of the last N commits.
//
// A high-churn DERIVED file is a factory-wide throughput bug: every merge
// invalidates every open PR. A high-churn SOURCE file is just a busy module.
// Churn is not contention: heavy churn with 0-1 open PRs means a busy file,
// not a conflict. Ported from the validated merge-hotspots.sh reference.
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { git, resolveTarget } from './append-point-scan.mjs';

const DERIVED_RES = [/\.gen\./, /\.generated\./, /generated/, /routeTree/, /\.snap$/, /snapshot/, /lock/, /\.lock$/, /CHANGELOG/, /schema\.json/, /openapi/, /\.d\.ts$/];

export function classify(file) {
  return DERIVED_RES.some((re) => re.test(file)) ? 'DERIVED' : 'source';
}

export function hotspots(dir, n) {
  const total = git(dir, 'log', `-${n}`, '--oneline').split('\n').filter(Boolean).length;
  if (total < 20) return { skip: true, total };
  const counts = new Map();
  for (const f of git(dir, 'log', `-${n}`, '--pretty=format:', '--name-only').split('\n')) {
    const t = f.trim();
    if (t) counts.set(t, (counts.get(t) ?? 0) + 1);
  }
  const rows = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12)
    .map(([file, count]) => ({ file, count, pct: Math.floor((count * 100) / total), kind: classify(file) }));
  return { skip: false, total, rows };
}

export function format(name, result, n) {
  if (result.skip) return `SKIP ${name} (only ${result.total} commits)\n`;
  let out = `=== ${name} (last ${result.total} commits) ===\n`;
  for (const r of result.rows) {
    out += `  ${String(r.count).padStart(3)} ${String(r.pct).padStart(3)}%  ${r.kind.padEnd(8)} ${r.file}${r.pct >= 5 ? ' <<<' : ''}\n`;
  }
  out += 'churn is not contention: a busy file only serializes merges when several PRs touch it at once.\n\n';
  return out;
}

export async function main(argv) {
  if (argv.includes('--help') || argv.includes('-h') || argv.length === 0) {
    process.stdout.write('Usage: merge-hotspots <local-dir|owner/repo> [N]\n');
    return argv.length === 0 ? 2 : 0;
  }
  const n = /^\d+$/.test(argv[1] ?? '') ? Number(argv[1]) : 300;
  const r = resolveTarget(argv[0]);
  if (r.error) {
    process.stderr.write(`${r.error}\n`);
    return 2;
  }
  if (r.skip) {
    process.stdout.write(`${r.skip}\n`);
    return 0;
  }
  process.stdout.write(format(argv[0], hotspots(r.dir, n), n));
  return 0;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main(process.argv.slice(2)).then((c) => { process.exitCode = c; }).catch((e) => { process.stderr.write(`${e.stack || e}\n`); process.exitCode = 1; });
}
