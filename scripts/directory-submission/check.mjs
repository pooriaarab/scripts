#!/usr/bin/env node
// directory-submission check — list, liveness-probe, or plan against the
// canonical directory list (directories.json, same folder).
//
//   node check.mjs list [--tier T] [--method M]
//   node check.mjs check [--tier T]      # probe every entry's url
//   node check.mjs plan <domain>         # per-domain checklist by method
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";

const HERE = dirname(new URL(import.meta.url).pathname);
const table = JSON.parse(readFileSync(join(HERE, "directories.json"), "utf8"));
const tiers = Object.keys(table).filter((k) => k !== "version" && k !== "note");

const args = process.argv.slice(2);
const cmd = args.shift();
const flag = (name) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? null : args[i + 1];
};

function entries(tierFilter, methodFilter) {
  const out = [];
  for (const tier of tiers) {
    if (tierFilter && tier !== tierFilter) continue;
    for (const e of table[tier]) {
      if (methodFilter && e.method !== methodFilter) continue;
      out.push({ tier, ...e });
    }
  }
  return out;
}

function fail(msg) {
  console.error(`check: ${msg}`);
  process.exit(1);
}

if (cmd === "list") {
  const rows = entries(flag("tier"), flag("method"));
  for (const e of rows) {
    console.log(`${e.tier}\t${e.name}\t${e.method ?? "-"}\t${e.cost ?? "-"}\t${e.link ?? "-"}\t${e.url}`);
  }
  console.log(`\n${rows.length} entries`);
} else if (cmd === "check") {
  const rows = entries(flag("tier"), flag("method"));
  const probe = async (e) => {
    try {
      const res = await fetch(e.url, {
        method: "HEAD",
        redirect: "follow",
        signal: AbortSignal.timeout(10_000),
      });
      if (res.status >= 200 && res.status < 500) return `${e.tier}\t${e.name}\t${res.status}`;
      const get = await fetch(e.url, { signal: AbortSignal.timeout(10_000) });
      return `${e.tier}\t${e.name}\t${get.status}`;
    } catch (err) {
      return `${e.tier}\t${e.name}\tDEAD ${err.message.slice(0, 60)}`;
    }
  };
  const results = [];
  const CHUNK = 6;
  for (let i = 0; i < rows.length; i += CHUNK) {
    results.push(...(await Promise.all(rows.slice(i, i + CHUNK).map(probe))));
  }
  let dead = 0;
  for (const r of results) {
    console.log(r);
    if (/\bDEAD\b|\t5\d\d|\t4\d\d/.test(r)) dead += 1;
  }
  console.log(`\n${rows.length - dead} alive, ${dead} dead/blocked`);
  if (dead > 0) process.exitCode = 2;
} else if (cmd === "plan") {
  const domain = args[0];
  if (!domain) fail("plan needs a domain, e.g. check.mjs plan example.com");
  const rows = entries(null, null);
  const order = ["api", "github-issue", "github-pr", "form-anon", "form-email", "verify-deploy", "form-account", "paid", "crawl", "pitch"];
  const byMethod = new Map();
  for (const e of rows) {
    const m = e.method ?? "unknown";
    if (!byMethod.has(m)) byMethod.set(m, []);
    byMethod.get(m).push(e);
  }
  console.log(`Submission plan for https://${domain}\n`);
  for (const m of order) {
    const list = byMethod.get(m);
    if (!list) continue;
    const label = { api: "agent can file it", "github-issue": "agent can file it", "github-pr": "agent can file it", "form-anon": "no account needed", "form-email": "needs a contact email", "verify-deploy": "needs a file/badge deployed on the domain", "form-account": "needs an account", paid: "paid only", crawl: "crawl-driven", pitch: "editorial, not a form" }[m] ?? m;
    console.log(`## ${m} — ${label}`);
    for (const e of list) {
      console.log(`- [ ] ${e.name} (${e.tier}) — ${e.submit} — ${e.gate}`);
    }
    console.log();
  }
} else {
  console.log(`usage:
  node check.mjs list [--tier T] [--method M]
  node check.mjs check [--tier T]
  node check.mjs plan <domain>

tiers: ${tiers.join(", ")}`);
}
