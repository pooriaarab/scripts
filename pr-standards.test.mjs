import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs, { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ConfigurationError,
  DEFAULT_CONFIG,
  checkSize,
  countClosingReferences,
  validateCommits,
  validateConfig,
  derivePrefix,
  loadConfig,
  matchesGlob,
  summarizeFiles,
  validateBody,
  validateBranchName,
  validateTitle,
} from './pr-standards.mjs';

const config = {
  ...DEFAULT_CONFIG,
  prefix: 'cr',
  minBodyChars: 120,
};

test('validates branch names and exempts protected branches', () => {
  assert.equal(validateBranchName('cr-142-fix-onboarding', config).ok, true);
  assert.equal(validateBranchName('cr-142-fix-onboarding-drop-off', config).ok, true);
  assert.equal(validateBranchName('main', config).exempt, true);
  assert.equal(validateBranchName('release/2026-08', config).exempt, true);
  assert.equal(validateBranchName('feature/nope', config).ok, false);
  assert.equal(validateBranchName('CR-142-fix-onboarding', config).ok, false);
  assert.equal(validateBranchName('cr-142-a', config).ok, false);
  assert.equal(validateBranchName(`cr-142-${'a'.repeat(49)}`, config).ok, false);
});

test('allows chore branches only when the config enables the escape', () => {
  assert.equal(validateBranchName('chore/update-deps', config).ok, false);
  assert.equal(
    validateBranchName('chore/update-deps', { ...config, allowChoreEscape: true }).choreEscape,
    true,
  );
});

test('derives prefixes from repository names', () => {
  assert.equal(derivePrefix('content-rabbit'), 'cr');
  assert.equal(derivePrefix('popcornteam'), 'pop');
  assert.equal(derivePrefix('imecore'), 'ime');
  assert.equal(derivePrefix('one-two-three-four-five'), 'ottf');
});

test('loadConfig uses the registry prefix for an unconfigured fleet repo', () => {
  // vibeads derives to vib, which twelve other repos also derive to. Only the
  // registry knows the collision was resolved to va.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-noconfig-'));
  try {
    const loaded = loadConfig(root, 'vibeads');
    assert.equal(loaded.config.prefix, 'va');
    assert.equal(loaded.prefixSource, 'registry');
    assert.match(loaded.provenance, /repo-prefixes\.json/);
    assert.notEqual(derivePrefix('vibeads'), 'va');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the repo config outranks the registry', () => {
  // The registry is the fleet's answer for a repo that has not decided. A repo
  // that has decided outranks it, or rolling out a config could not change a
  // prefix and every repo would be pinned to whatever the registry said.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-config-'));
  try {
    fs.mkdirSync(path.join(root, '.github'));
    fs.writeFileSync(path.join(root, '.github', 'pr-standards.json'), '{"prefix":"zz"}');
    const loaded = loadConfig(root, 'vibeads');
    assert.equal(loaded.config.prefix, 'zz');
    assert.equal(loaded.prefixSource, 'config');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the registry is found beside the checker, not beside the repo', () => {
  // In CI the checker is unpacked into a temp directory and run against a
  // different repo's checkout, so a path resolved against the working directory
  // finds nothing and every repo silently falls back to derivation.
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-elsewhere-'));
  try {
    const launcher = fileURLToPath(new URL('./pr-standards', import.meta.url));
    const result = spawnSync(process.execPath, [launcher, 'precheck',
      '--branch', 'va-1-some-slug', '--title', '[VA-1] Do a thing here'], {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GITHUB_REPOSITORY: 'pooriaarab/vibeads' },
    });
    assert.match(result.stdout, /Using prefix: va \(from repo-prefixes\.json\)/);
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('an unreadable registry falls through to derivation', () => {
  // The registry is a convenience, not a dependency. If it is ever absent or
  // corrupt the checker has to keep judging pull requests, so this asserts the
  // catch actually falls through rather than surfacing as a configuration
  // error that would fail every PR in the fleet at once.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-badregistry-'));
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    for (const f of ['pr-standards', 'pr-standards.mjs']) {
      fs.copyFileSync(path.join(here, f), path.join(dir, f));
    }
    fs.chmodSync(path.join(dir, 'pr-standards'), 0o755);
    fs.writeFileSync(path.join(dir, 'repo-prefixes.json'), '{ not json');
    const result = spawnSync(process.execPath, [path.join(dir, 'pr-standards'), 'precheck',
      '--branch', 'vib-1-some-slug', '--title', '[VIB-1] Do a thing here'], {
      cwd: dir,
      encoding: 'utf8',
      env: { ...process.env, GITHUB_REPOSITORY: 'pooriaarab/vibeads' },
    });
    // Exit 2 is the configuration-error code, which is what a throw would give.
    assert.notEqual(result.status, 2, result.stdout + result.stderr);
    assert.match(result.stdout, /Using prefix: vib \(derived/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadConfig derives a prefix for a repo absent from config and registry', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-new-'));
  try {
    const loaded = loadConfig(root, 'brand-new-repo');
    assert.equal(loaded.config.prefix, 'bnr');
    assert.equal(loaded.prefixSource, 'derived');
    assert.match(loaded.provenance, /derived/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('always derives a prefix the config will accept', () => {
  // `a-` and `---` are 2 and 3 characters, so they sailed past both length
  // fallbacks and were rejected later by loadConfig with a message about the
  // config rather than about the name. That is the exact failure derivePrefix
  // exists to prevent, so the guard belongs here rather than downstream.
  const valid = /^[a-z]{2,4}$/;
  for (const name of ['a-', '---', '-', '__', 'a', 'x1', '123', '9', '3d-tools']) {
    assert.match(derivePrefix(name), valid, `derivePrefix(${JSON.stringify(name)})`);
  }
  assert.equal(derivePrefix('a-'), 'aa');
  assert.equal(derivePrefix('---'), 'zz');
});

test('rejects issue number zero and leading zeros in a branch name', () => {
  // The prose documented [0-9]+ while the validator used [1-9][0-9]*. One issue
  // must have exactly one branch name, so `cr-0-x` and `cr-007-x` are not valid.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  assert.equal(validateBranchName('cr-0-fix-the-thing', config).ok, false);
  assert.equal(validateBranchName('cr-007-fix-the-thing', config).ok, false);
  assert.equal(validateBranchName('cr-7-fix-the-thing', config).ok, true);
});

test('accepts a correctly formatted imperative title', () => {
  assert.equal(validateTitle('[CR-142] Fix onboarding drop-off', 'cr', 142).ok, true);
});

test('checks every title rule', () => {
  const cases = [
    ['[PT-142] Fix onboarding drop-off', 'the prefix must match the configured prefix'],
    ['[CR-143] Fix onboarding drop-off', 'the issue number must match the branch'],
    ['CR-142 Fix onboarding drop-off', 'the title tag is required'],
    ['[CR-142] fix onboarding drop-off', 'the subject must start with a capital'],
    ['[CR-142] Fix it', 'the subject is too short'],
    [`[CR-142] ${'Fix '.repeat(13)}`, 'the subject is too long'],
    ['[CR-142] Fix onboarding drop-off.', 'the subject cannot end with a period'],
    ['[CR-142] Added onboarding drop-off', 'Added is not imperative'],
    ['[CR-142] Fixed onboarding drop-off', 'Fixed is not imperative'],
    ['[CR-142] Updated onboarding drop-off', 'Updated is not imperative'],
    ['[CR-142] Removed onboarding drop-off', 'Removed is not imperative'],
    ['[CR-142] Changed onboarding drop-off', 'Changed is not imperative'],
    ['[CR-142] Refactored onboarding drop-off', 'Refactored is not imperative'],
    ['[CR-142] Implemented onboarding drop-off', 'Implemented is not imperative'],
    ['[CR-142] Fixing onboarding drop-off', '-ing openers are not imperative'],
    ['[CR-142] Fix onboarding 🚀 drop-off', 'emoji is not allowed'],
    ['[CR-142] fix: onboarding drop-off', 'conventional commit prefixes are not allowed'],
  ];

  for (const [title, reason] of cases) {
    assert.equal(validateTitle(title, 'cr', 142).ok, false, reason);
  }
});

const validBody = `Closes #142

## What
Fixes the onboarding drop-off after step three.

## Why
Issue #142 reports that users lose their progress at this step. This change keeps the progress state.

## How I verified
bun test -> 214 passed

Assisted-by: claude-personal:claude-opus-5`;

test('requires one matching closing reference and the required body sections', () => {
  assert.equal(countClosingReferences(validBody).length, 1);
  assert.equal(validateBody(validBody, 142, config).ok, true);
  assert.equal(validateBody(validBody.replace('Closes #142', 'Closes #142\nFixes #142'), 142, config).ok, false);
  assert.equal(validateBody(validBody.replace('Closes #142', 'Closes #7'), 142, config).ok, false);
  assert.equal(validateBody(validBody.replace('## Why', '## Missing'), 142, config).ok, false);
  assert.equal(validateBody(validBody.replace('bun test -> 214 passed', 'TODO'), 142, config).ok, false);
  assert.equal(validateBody(validBody.replace('Assisted-by: claude-personal:claude-opus-5', ''), 142, config).ok, false);
  assert.equal(validateBody('<!-- template -->', 142, config).ok, false);
});

test('matches the supported exclusion glob forms', () => {
  assert.equal(matchesGlob('app.lock', '**/*.lock'), true);
  assert.equal(matchesGlob('packages/app.lock', '**/*.lock'), true);
  assert.equal(matchesGlob('dist/bundle.js', 'dist/**'), true);
  assert.equal(matchesGlob('packages/foo/generated/data.ts', '**/generated/**'), true);
  assert.equal(matchesGlob('logo.svg', '**/*.{svg,png}'), true);
  assert.equal(matchesGlob('images/logo.png', '**/*.{svg,png}'), true);
  assert.equal(matchesGlob('src/logo.gif', '**/*.{svg,png}'), false);
  assert.equal(matchesGlob('src/a/b.js', 'src/*.js'), false);
});

test('counts changed lines after exclusions and reports raw totals', () => {
  const summary = summarizeFiles([
    { filename: 'src/app.js', additions: 200, deletions: 100 },
    { filename: 'dist/app.js', additions: 700, deletions: 100 },
    { filename: 'src/logo.svg', additions: 5, deletions: 5 },
  ], config);

  assert.deepEqual(summary, {
    rawLines: 1110,
    countedLines: 300,
    excludedLines: 810,
    rawFiles: 3,
    countedFiles: 1,
    excludedFiles: 2,
    topLevelDirs: ['src'],
  });
  assert.equal(checkSize(summary, { ...config, maxLines: 250 }).failures.length, 1);
});

test('no label clears the size cap', () => {
  // The cap used to have an escape: an owner-applied `oversized-approved`
  // label. Every escape from a design constraint becomes the path — an agent
  // told it may ask for the label asks for the label instead of decomposing
  // the work, which is the one thing the cap exists to force.
  //
  // The remaining escape is outside this checker: a person merges past a red
  // check. That is a deliberate act on a named pull request, it cannot be
  // requested in a body, and it leaves a record.
  const summary = {
    rawLines: 900,
    countedLines: 700,
    excludedLines: 200,
    rawFiles: 45,
    countedFiles: 45,
    excludedFiles: 0,
    topLevelDirs: ['a', 'b', 'c', 'd'],
  };
  const result = checkSize(summary, { ...config, maxLines: 500, maxFiles: 40 });
  assert.equal(result.failures.some((f) => f.check === 'PR size'), true);
  assert.equal(result.failures.some((f) => f.check === 'changed files'), true);
  // The fix text must not send anyone looking for a label that no longer
  // exists. Saying no label clears it is the point; naming one to request is
  // the bug, because the instruction is what an agent acts on.
  assert.equal(result.failures.every((f) => !/oversized-approved|ask the repo owner/i.test(f.fix)), true);
  assert.equal(result.failures.every((f) => /split the change/i.test(f.fix)), true);
  // A repo config that still carries the old keys is simply ignored, rather
  // than reviving the escape or throwing on a stale file.
  const stale = checkSize(summary, { ...config, maxLines: 500, maxFiles: 40, overrideLabel: 'oversized-approved', overrideActors: ['someone'] });
  assert.equal(stale.failures.length, 2);
});
test('enforces rules for chore branches (null issue)', () => {
  assert.equal(validateTitle('Added something', 'cr', null).ok, false);
  assert.equal(validateBody(validBody.replace('bun test -> 214 passed', 'TODO').replace('Closes #142\n\n', ''), null, config).ok, false);
});

test('fails a chore branch with a Closes reference', () => {
  assert.equal(validateBody(validBody, null, config).ok, false);
});

import { main } from './pr-standards.mjs';

test('an exempt branch still skips title and body entirely', async () => {
  const originalWrite = process.stdout.write;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  try {
    const exitCode = await main(['precheck', '--branch', 'main', '--title', 'bad past tense title without tag', '--json']);
    assert.equal(exitCode, 0);
    const result = JSON.parse(output);
    assert.equal(result.failures.length, 0);
  } finally {
    process.stdout.write = originalWrite;
  }
});

test('issues/{n} returning an object with a pull_request field fails', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = ''; // disable gh
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo'; // Ensure we don't hit the CI check

  globalThis.fetch = async (url) => {
    if (url.includes('contents/.github/pr-standards.json')) {
      return { ok: true, json: async () => ({ content: Buffer.from(JSON.stringify({ prefix: 'cr' })).toString('base64'), encoding: 'base64' }) };
    }
    if (url.includes('pulls/12/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Fix the thing' } }]) };
    }
    if (url.includes('pulls/12/files')) {
      return { ok: true, json: async () => ([]) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test' }, title: '[CR-12] Test PR', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
    }
    if (url.includes('issues/12')) {
      return { ok: true, json: async () => ({ state: 'open', pull_request: {} }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '12', '--json']);
    assert.equal(exitCode, 1);
    const result = JSON.parse(output);
    assert.equal(result.failures.some(f => f.check === 'branch issue' && f.got === '#12 is a pull request'), true);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('config resolution prefers the target repo over the local checkout', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = ''; // disable gh
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo'; // Ensure we don't hit the CI check

  globalThis.fetch = async (url) => {
    if (url.includes('contents/.github/pr-standards.json')) {
      return { ok: true, json: async () => ({ content: Buffer.from(JSON.stringify({ prefix: 'rmt' })).toString('base64'), encoding: 'base64' }) };
    }
    if (url.includes('pulls/12/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Fix the thing' } }]) };
    }
    if (url.includes('pulls/12/files')) {
      return { ok: true, json: async () => ([]) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'rmt-12-test' }, title: '[RMT-12] Test PR that works', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
    }
    if (url.includes('issues/12')) {
      return { ok: true, json: async () => ({ state: 'open' }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '12', '--json']);
    assert.equal(exitCode, 0);
    const result = JSON.parse(output);
    assert.equal(result.prefix, 'rmt');
    assert.equal(result.provenance, 'from test/repo .github/pr-standards.json');
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('counts every GitHub closing keyword, not only Closes and Fixes', () => {
  // GitHub honours nine keywords. A checker that knows two of them lets a PR
  // close two issues while reporting one.
  for (const keyword of ['Close', 'Closes', 'Closed', 'Fix', 'Fixes', 'Fixed', 'Resolve', 'Resolves', 'Resolved']) {
    assert.deepEqual(countClosingReferences(`${keyword} #7`), [{ repo: null, number: 7 }], `missed ${keyword}`);
  }
  assert.deepEqual(countClosingReferences('Closes #1\n\nResolves #2'), [{ repo: null, number: 1 }, { repo: null, number: 2 }]);
  // GitHub accepts a colon after the keyword and a cross-repo reference.
  assert.deepEqual(countClosingReferences('Closes: #4'), [{ repo: null, number: 4 }]);
  assert.deepEqual(countClosingReferences('Fixes octo-org/octo-repo#100'), [{ repo: 'octo-org/octo-repo', number: 100 }]);
  assert.equal(countClosingReferences('Closes #1\nFixes: #2').length, 2);
  assert.deepEqual(countClosingReferences('closes #3'), [{ repo: null, number: 3 }]);
  // A comment is not a closing reference, and neither is prose about closing.
  assert.deepEqual(countClosingReferences('<!-- Closes #9 -->'), []);
  assert.deepEqual(countClosingReferences('This closes the gap'), []);
});

test('rejects an AI attribution trailer and spares a human co-author', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (message) => [{ sha: 'abc1234', commit: { message: `Fix a thing\n\n${message}` } }];

  for (const banned of [
    'Co-Authored-By: Claude <noreply@anthropic.com>',
    'Co-authored-by: Claude',
    'Co-authored-by: Codex',
    'Co-authored-by: Gemini',
    '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
  ]) {
    assert.equal(validateCommits(commit(banned), config).ok, false, `missed ${banned}`);
  }

  // The owner's own review bot is a real author, not a model taking credit.
  assert.equal(validateCommits(commit('Co-authored-by: vibecodereview'), config).ok, true);

  // A name that merely contains a banned token must not be rejected: `pi`
  // inside Pia, `GPT` inside Gupta, `Muse` inside Museveni.
  for (const human of [
    'Co-authored-by: Pooria Arab <p@example.com>',
    'Co-authored-by: Pia Gupta <pia@example.com>',
    'Co-authored-by: Museveni Okello <m@example.com>',
  ]) {
    assert.equal(validateCommits(commit(human), config).ok, true, `false positive on ${human}`);
  }
});

test('a truncated commit list fails rather than passing on what it saw', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  assert.equal(validateCommits([], config, true).ok, false);
  assert.equal(validateCommits([], config, false).ok, true);
});

test('bannedCommitTrailers is configurable', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr', bannedCommitTrailers: ['Zephyr'] };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Co-authored-by: Zephyr'), config).ok, false);
  // Claude is not in this repo's list, so it is allowed here.
  assert.equal(validateCommits(commit('Co-authored-by: Claude'), config).ok, true);
});

test('a banned name cannot be smuggled in alongside the exempt review bot', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Co-authored-by: vibecodereview Claude <claude@anthropic.com>'), config).ok, false);
});

test('a human co-author is not failed for an email domain that contains a banned name', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Co-authored-by: Jane Doe <jane@openai.com>'), config).ok, true);
  assert.equal(validateCommits(commit('Co-authored-by: Jane Doe <jane@anthropic.com>'), config).ok, true);
});

test('the marketing footer check does not fire on ordinary prose mentioning it', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Remove "Generated with Claude Code" from the output'), config).ok, true);
});

test('the marketing footer check catches other agents, not only Claude Code', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  for (const footer of [
    '🤖 Generated with Gemini CLI',
    'Generated with Codex',
    'Generated by Copilot',
  ]) {
    assert.equal(validateCommits(commit(footer), config).ok, false, `missed ${footer}`);
  }
  // A footer-shaped line naming no banned agent is not a violation.
  assert.equal(validateCommits(commit('Generated with love'), config).ok, true);
});

test('bannedCommitTrailers rejects blank entries instead of matching every co-author line', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr', bannedCommitTrailers: [''] };
  assert.throws(() => validateConfig(config), ConfigurationError);
});

test('the marketing footer check catches multi-codepoint emoji, not only a bare pictograph', () => {
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  for (const footer of [
    // Robot face plus an explicit variation selector (U+FE0F).
    '🤖️ Generated with Claude',
    // "Technologist": woman + ZWJ (U+200D) + computer, three codepoints.
    '👩‍💻 Generated with Claude',
  ]) {
    assert.equal(validateCommits(commit(footer), config).ok, false, `missed ${JSON.stringify(footer)}`);
  }
});

test('a banned name with punctuation still matches', () => {
  // \b needs a word/non-word transition, so it never fires beside a name that
  // starts with punctuation. Only reachable through the documented config, which
  // is where a silent pass is hardest to notice.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr', bannedCommitTrailers: ['@cursor', 'pi'] };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Co-authored-by: @cursor <c@example.com>'), config).ok, false);
  assert.equal(validateCommits(commit('Co-authored-by: pi <p@example.com>'), config).ok, false);
  assert.equal(validateCommits(commit('Co-authored-by: mycursor <c@example.com>'), config).ok, true);
  assert.equal(validateCommits(commit('Co-authored-by: Pia Gupta <p@example.com>'), config).ok, true);
});

test('a punctuation-prefixed banned name still matches inside a markdown footer link', () => {
  // The boundary for a name starting with punctuation must reject only a
  // preceding word character, not any preceding non-whitespace: a real footer
  // wraps the name in a markdown link, e.g. `[@cursor](https://cursor.sh)`,
  // and the `[` immediately before `@cursor` is not whitespace.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr', bannedCommitTrailers: ['@cursor'] };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Generated with [@cursor](https://cursor.sh)'), config).ok, false);
});

test('a banned name after the email delimiter is not discarded', () => {
  // Truncating at the first `<` threw away everything after the email too, so
  // `vibecodereview <bot@example.com> Claude` read as the exempt bot alone.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Co-authored-by: vibecodereview <bot@example.com> Claude'), config).ok, false);
  assert.equal(validateCommits(commit('Co-authored-by: vibecodereview <bot@example.com>'), config).ok, true);
  // The reason the email is stripped at all: a human must not fail for a domain.
  assert.equal(validateCommits(commit('Co-authored-by: Jane Doe <jane@anthropic.com>'), config).ok, true);
});

test('an Assisted-by trailer is the required PR-body disclosure only, not a commit trailer', () => {
  // The standard names one exception for Assisted-by: the pull request body.
  // The same trailer in a commit message is the credit-in-every-commit the
  // rule bans, so it fails regardless of which agent it names.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Assisted-by: claude-personal:claude-opus-5'), config).ok, false);
  // Unconditional: it fails even when the named agent is not on the banned list.
  assert.equal(validateCommits(commit('Assisted-by: some-repo-local:some-model'), config).ok, false);
});

test('a marketing footer link target does not decide the outcome, only the disclosed name does', () => {
  // The footer check used to test the banned-name regex against the whole
  // line, so a URL coincidentally containing a banned word (here "cursor")
  // failed a PR whose actual, unbanned, agent was Zephyr.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr' };
  const commit = (m) => [{ sha: 'abc1234', commit: { message: `Fix\n\n${m}` } }];
  assert.equal(validateCommits(commit('Generated with Zephyr (https://cursor.example/docs)'), config).ok, true);
  assert.equal(validateCommits(commit('Generated with Zephyr, see https://cursor.example/docs'), config).ok, true);
  // A banned agent must still be caught when named alongside an unrelated URL.
  assert.equal(validateCommits(commit('Generated with Claude (https://claude.com/claude-code)'), config).ok, false);
});

test('bannedCommitTrailers rejects a padded entry instead of configuring a name that can never match', () => {
  // `\bClaude\b` never matches " Claude " with its own leading/trailing
  // spaces folded into the literal, which silently disabled that ban.
  const config = { ...DEFAULT_CONFIG, prefix: 'cr', bannedCommitTrailers: [' Claude '] };
  assert.throws(() => validateConfig(config), ConfigurationError);
});

test('the rollout template states a decision, never a copy of a default', () => {
  // A copied default is not a no-op. loadConfig merges the file over
  // DEFAULT_CONFIG, so a repo carrying the full set is pinned to the values of
  // the day it was rolled out, and a fixed default never reaches it -- which is
  // the opposite of what one central checker is for.
  const template = JSON.parse(readFileSync(new URL('./pr-standards-templates/pr-standards.json', import.meta.url), 'utf8'));
  for (const [key, value] of Object.entries(template)) {
    if (key === 'prefix') continue;
    assert.notDeepEqual(value, DEFAULT_CONFIG[key], `${key} in the template equals the default, so it pins every rolled-out repo to today's value`);
  }
  // The placeholder the rollout substitutes must survive, or every repo gets
  // the literal string as its prefix.
  assert.equal(template.prefix, '__PREFIX__');
});

test('the CI bundle includes the registry beside the checker', () => {
  // The checker reads repo-prefixes.json from its own directory, so the fetch
  // step has to put it there. Unpacking the whole tag does that for free; a
  // step that named individual files would have to list the registry too, and
  // omitting it would leave every unadopted repo silently deriving a prefix.
  const workflow = readFileSync(new URL('./pr-standards-templates/pr-standards.yml', import.meta.url), 'utf8');
  assert.match(workflow, /tar -xzf \S+ -C \S+ --strip-components=1\s*$/m);
  assert.doesNotMatch(workflow, /for f in pr-standards/);
});

test('a lockfile is excluded wherever a workspace keeps it', () => {
  // The explicit lockfile names were anchored at the repo root, so a monorepo
  // counted apps/*/package-lock.json against the 500-line cap and a dependency
  // bump failed the size check on generated lines nobody reads.
  for (const path of [
    'package-lock.json', 'apps/website/package-lock.json',
    'apps/api/bun.lockb', 'packages/x/pnpm-lock.yaml',
    'crates/y/Cargo.lock', 'services/z/yarn.lock',
  ]) {
    assert.ok(
      DEFAULT_CONFIG.excludeGlobs.some((glob) => matchesGlob(path, glob)),
      `${path} is counted against the cap`,
    );
  }
  // Still counts a real source file that merely lives near one.
  assert.equal(DEFAULT_CONFIG.excludeGlobs.some((glob) => matchesGlob('apps/website/src/lock-screen.ts', glob)), false);
});

test('the proof escape hatch does not read as a refusal to answer', () => {
  // `Proof: n/a — <reason>` is the documented escape hatch, and the docs say to
  // write it under `## How I verified`. The N/A guard matched it there, so
  // every pull request that used the hatch correctly failed the body check —
  // with a message about lazy verification that never named the line. Two rules
  // the standard defines, contradicting each other.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const verifiedFails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');

  // A real command and result, plus the hatch, passes.
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nProof: n/a — a CLI check with no visible surface at all.'), false);
  // The hatch with no command and no result still fails: it waives the media,
  // never the verification.
  assert.equal(verifiedFails('Proof: n/a — a CLI check with no visible surface at all.'), true);
  // A bare N/A is still a refusal.
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nN/A'), true);
  // So is a TODO, and so is "tested locally".
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nTODO: check the rest'), true);
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\ntested locally'), true);
  // A hatch with no reason after the dash is not a valid hatch, so the guard
  // still sees the n/a.
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nProof: n/a'), true);
  // A hatch whose "reason" is only whitespace has no reason either. Dropping
  // the whole line (instead of swapping in the reason) would have hidden the
  // n/a from the guard and let this through.
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nProof: n/a —    '), true);
  // A hatch reason that is itself just "TODO" or "N/A" is still a refusal.
  // Dropping the whole matching line would have hidden the refusal token
  // along with the harmless "n/a" prefix.
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nProof: n/a — TODO'), true);
  assert.equal(verifiedFails('`node --test` -> 40 passed\n\nProof: n/a — N/A'), true);
});

test('a quoted rule name is not a refusal to answer', () => {
  // A body that explains the rule inside the section the rule reads was failed
  // by its own explanation, and the message named nothing. This pull request's
  // own body hit it, which is the only reason it was found: the guard reads
  // prose, and prose about verification vocabulary is indistinguishable from a
  // refusal unless quoting is respected.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');
  const run = '`node --test` -> 41 passed';

  // Inline code is a quotation, not a claim.
  assert.equal(fails(`${run}\n\nThe test rejects a bare \`N/A\`, a \`TODO\`, and \`tested locally\`.`), false);
  // So is a fenced block, which is where command output belongs.
  assert.equal(fails(`${run}\n\n\`\`\`\nN/A\nTODO\n\`\`\``), false);
  // Unquoted, they are still a refusal.
  assert.equal(fails(`${run}\n\nN/A`), true);
  assert.equal(fails(`${run}\n\ntested locally`), true);
  // Stripping the quotes must not also strip the evidence: a section whose only
  // command sits in a fence still passes, because hasCommandAndResult reads the
  // raw section rather than the stripped one.
  assert.equal(fails('```\n$ node --test\nℹ pass 41\n```'), false);
});
