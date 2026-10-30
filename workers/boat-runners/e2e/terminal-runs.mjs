// Failure cases written before the broker change: terminal/deleted parent with
// queued child, failed parent lookup, live queue, rerun, and stale reconciliation.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import ts from 'typescript';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = process.argv.indexOf('--artifacts');
const artifacts = output < 0 ? mkdtempSync(join(tmpdir(), 'boat-terminal-runs-')) : resolve(process.argv[output + 1]);
mkdirSync(artifacts, { recursive: true });
const compiled = join(artifacts, 'broker.mjs');
writeFileSync(compiled, ts.transpileModule(readFileSync(join(root, 'src/index.ts'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
}).outputText);
const { default: worker, BrokerDO } = await import(pathToFileURL(compiled));
const secret = 'fixture-secret-must-not-appear-in-receipt';
const nativeNow = Date.now;
let clock = nativeNow();
Date.now = () => clock;

function fixture(parent = 'completed', lookupStatus = 200, jobLookupStatus = 200) {
  let parentState = parent;
  const db = new DatabaseSync(':memory:');
  const storage = {
    sql: { exec(sql, ...args) { const rows = db.prepare(sql).all(...args); return { toArray: () => rows }; } },
    transactionSync(fn) {
      db.exec('BEGIN');
      try { const result = fn(); db.exec('COMMIT'); return result; }
      catch (error) { db.exec('ROLLBACK'); throw error; }
    },
  };
  let mints = 0;
  const env = { WEBHOOK_SECRET: secret, POOL_TOKEN: secret };
  const broker = new BrokerDO({ storage }, env);
  env.BROKER = { idFromName: () => 'broker', get: () => ({ fetch: (req, init) => broker.fetch(req instanceof Request ? req : new Request(req, init)) }) };
  // Only GitHub transport is replaced. Router, signatures, SQL, claims, cleanup,
  // and reconciliation execute the real broker code.
  broker.gh = async (path, method = 'GET') => {
    clock += 30_000; // Advance long-poll time without sleeping in the scenarios.
    if (method === 'DELETE') return new Response(null, { status: 204 });
    if (path.endsWith('/generate-jitconfig')) {
      mints++;
      return Response.json({ runner: { id: 7 }, encoded_jit_config: 'dummy-jit-secret' });
    }
    if (path === '/repos/pooriaarab/fixture') return Response.json({ private: true });
    if (path.includes('/actions/jobs/')) return jobLookupStatus === 200 ? Response.json({ id: 101, run_id: 100, status: 'queued', labels: ['boat'] }) : Response.json({}, { status: jobLookupStatus });
    if (path === '/repos/pooriaarab/fixture/actions/runs/100') {
      return lookupStatus === 200 ? Response.json({ id: 100, status: parentState }) : Response.json({ error: 'lookup refused' }, { status: lookupStatus });
    }
    if (path.includes('/actions/runs?')) {
      return Response.json({ workflow_runs: parentState !== 'completed' && path.includes(`status=${parentState}`) ? [{ id: 100 }] : [] });
    }
    if (path.includes('/actions/runs/100/jobs')) return Response.json({ jobs: [{ id: 101, run_id: 100, status: 'queued', labels: ['boat'] }] });
    if (path.includes('/actions/runners')) return Response.json({ runners: [] });
    throw new Error('Unexpected fake GitHub route');
  };
  const request = (path, init = {}) => worker.fetch(new Request(`https://fixture.invalid${path}`, {
    ...init, headers: { authorization: `Bearer ${secret}`, ...init.headers },
  }), env);
  async function seed() {
    const body = JSON.stringify({ action: 'queued', repository: { private: true, full_name: 'pooriaarab/fixture' }, workflow_job: { id: 101, run_id: 100, labels: ['boat'] } });
    const signature = 'sha256=' + createHmac('sha256', secret).update(body).digest('hex');
    const response = await request('/webhook', { method: 'POST', body, headers: { 'x-github-event': 'workflow_job', 'x-hub-signature-256': signature } });
    assert.equal(response.status, 200);
  }
  return { db, broker, env, request, seed, setParent: value => { parentState = value; }, mints: () => mints, jobs: () => broker.rows('SELECT * FROM jobs') };
}

const results = [];
async function scenario(name, check) {
  const started = performance.now();
  try { const observed = await check(); results.push({ name, passed: true, durationMs: Math.round(performance.now() - started), ...observed }); }
  catch (error) { results.push({ name, passed: false, durationMs: Math.round(performance.now() - started), error: error.message }); }
}
try {
  for (const [name, status] of [['completed parent', 200], ['deleted parent', 404]]) {
    await scenario(`${name} refuses queued child before runner creation`, async () => {
      const f = fixture('completed', status);
      try {
        await f.seed();
        const response = await f.request('/lease?label=boat&box=fixture');
        assert.equal(response.status, 204);
        assert.equal(f.mints(), 0);
        assert.equal(f.jobs().length, 0);
        return { status: response.status, runnerMints: f.mints(), jobsRemaining: f.jobs().length };
      } finally { f.db.close(); }
    });
  }
  for (const lookupStatus of [403, 503]) {
    await scenario(`parent lookup ${lookupStatus} preserves queued work`, async () => {
      const f = fixture('in_progress', lookupStatus);
      try {
        await f.seed();
        const response = await f.request('/lease?label=boat&box=fixture');
        assert.equal(response.status, 502);
        assert.equal(f.mints(), 0);
        assert.equal(f.jobs().length, 1);
        return { status: response.status, runnerMints: f.mints(), jobsRemaining: f.jobs().length };
      } finally { f.db.close(); }
    });
  }
  for (const parent of ['queued', 'in_progress']) {
    await scenario(`live ${parent} parent allocates a runner`, async () => {
      const f = fixture(parent);
      try {
        await f.seed();
        const response = await f.request('/lease?label=boat&box=fixture');
        assert.equal(response.status, 200);
        assert.equal(f.mints(), 1); // Positive control proves the mint counter works.
        return { status: response.status, runnerMints: f.mints() };
      } finally { f.db.close(); }
    });
  }
  for (const [parent, lookupStatus, remaining] of [['completed', 200, 0], ['completed', 404, 0], ['in_progress', 503, 1]]) {
    await scenario(`reconcile parent ${parent}/${lookupStatus} leaves ${remaining} jobs`, async () => {
      const f = fixture(parent, lookupStatus);
      try {
        await f.seed();
        let failed = false;
        try { await worker.scheduled({}, f.env); } catch { failed = true; }
        assert.equal(f.jobs().length, remaining);
        assert.equal(f.mints(), 0);
        assert.equal(failed, lookupStatus === 503);
        return { jobsRemaining: f.jobs().length, runnerMints: f.mints(), retryRequired: failed };
      } finally { f.db.close(); }
    });
  }
  await scenario('reconcile retires stale queue but keeps independent runner lease', async () => {
    const f = fixture('in_progress');
    try {
      await f.seed();
      assert.equal((await f.request('/lease?label=boat&box=fixture')).status, 200);
      f.setParent('completed');
      await worker.scheduled({}, f.env);
      assert.equal(f.jobs().length, 0);
      assert.equal(f.broker.rows('SELECT * FROM leases WHERE closing=0').length, 1);
      return { jobsRemaining: 0, independentLeases: 1 };
    } finally { f.db.close(); }
  });
  await scenario('reconcile removes a job deleted with its run', async () => {
    const f = fixture('completed', 404, 404);
    try {
      await f.seed();
      await worker.scheduled({}, f.env);
      assert.equal(f.jobs().length, 0);
      return { jobsRemaining: 0, runnerMints: f.mints() };
    } finally { f.db.close(); }
  });
} finally { Date.now = nativeNow; }
const receipt = { scenarios: results, secretExcluded: !JSON.stringify(results).includes(secret) && !JSON.stringify(results).includes('dummy-jit-secret') };
writeFileSync(join(artifacts, 'receipt.json'), JSON.stringify(receipt, null, 2));
console.log(JSON.stringify(receipt, null, 2));
if (results.some(row => !row.passed) || !receipt.secretExcluded) process.exitCode = 1;
