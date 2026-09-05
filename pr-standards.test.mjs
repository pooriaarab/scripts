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
  checkProof,
  checkBaseBranchAge,
  checkSize,
  countClosingReferences,
  validateCommits,
  validateConfig,
  derivePrefix,
  hasUiDiff,
  isCommittedProofMedia,
  isUiFile,
  loadConfig,
  matchesGlob,
  summarizeFiles,
  multisetDifference,
  backfillMissingPatches,
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

test('one Assisted-by trailer per line, and the failure names the line it found', () => {
  // Two pull requests failed this check in one day with "got: missing" while
  // their bodies carried `Assisted-by: muse:meta-code,
  // claude-personal-1:claude-opus-5`. Most work here has two or more
  // contributors, so the comma list is the common failure, and a message that
  // denies the line sends the author hunting for a line they already wrote.
  const bodyWithTrailer = (trailer) =>
    validBody.replace('Assisted-by: claude-personal:claude-opus-5', trailer);
  const assistedBy = (r) => r.failures.find((f) => f.check === 'Assisted-by line');

  // Two trailers on two lines is the accepted shape.
  assert.equal(validateBody(
    bodyWithTrailer('Assisted-by: muse:meta-code\nAssisted-by: claude-personal-1:claude-opus-5'), 142, config,
  ).ok, true);

  // The comma list still fails: the fix is a second line, not a looser match.
  const commaList = validateBody(
    bodyWithTrailer('Assisted-by: muse:meta-code, claude-personal-1:claude-opus-5'), 142, config,
  );
  assert.equal(commaList.ok, false);
  assert.equal(
    assistedBy(commaList).got.includes('Assisted-by: muse:meta-code, claude-personal-1:claude-opus-5'),
    true,
    'the failure reports the line it found, not "missing"',
  );
  assert.notEqual(assistedBy(commaList).got, 'missing');

  // A body with no trailer at all is the one case "missing" still describes.
  const absent = validateBody(validBody.replace('Assisted-by: claude-personal:claude-opus-5', ''), 142, config);
  assert.equal(assistedBy(absent).got, 'missing');

  // A valid first line must not shield a malformed second line: checking
  // only "does some line match" instead of "does every line match" would
  // let this pass.
  const mixedLines = validateBody(
    bodyWithTrailer('Assisted-by: muse:meta-code\nAssisted-by: muse:meta-code, claude:opus'), 142, config,
  );
  assert.equal(mixedLines.ok, false);
  assert.notEqual(assistedBy(mixedLines).got, undefined);

  // A comma list with no space after the comma has no whitespace for
  // `[^\s]+` to stop at, so the fields must also reject commas directly.
  const commaListNoSpace = validateBody(
    bodyWithTrailer('Assisted-by: muse:meta-code,claude-personal-1:claude-opus-5'), 142, config,
  );
  assert.equal(commaListNoSpace.ok, false);
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
    grossCountedLines: 300,
    // No patch text on these fixtures, so no move can be proven and nothing is
    // discounted. That is the intended direction: prove it or pay for it.
    movedLines: 0,
    excludedLines: 810,
    rawFiles: 3,
    countedFiles: 1,
    excludedFiles: 2,
    topLevelDirs: ['src'],
  });
  assert.equal(checkSize(summary, { ...config, maxLines: 250 }).failures.length, 1);
});

test('enforces size failures without a label escape', () => {
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

  assert.equal(result.failures.length, 2);
  assert.equal(result.warnings.length, 1);
});

test('reports stale branch points at the configured threshold', () => {
  const compare = { behind_by: 11, merge_base_commit: { sha: '1234567890' } };
  const baseChanges = {
    commits: [{ sha: 'abcdef123', commit: { message: 'Remove the escape hatch\n\nDetails' } }],
    files: [{ filename: 'pr-standards.mjs' }],
  };

  assert.deepEqual(checkBaseBranchAge({ ...compare, behind_by: 0 }, baseChanges, [], config), {
    failures: [], warnings: [],
  }, 'an up-to-date branch is silent');

  const stale = checkBaseBranchAge(compare, baseChanges, [{ filename: 'README.md' }], config);
  assert.equal(stale.failures.length, 0);
  assert.equal(stale.warnings.length, 1);
  assert.match(stale.warnings[0].got, /abcdef1 Remove the escape hatch/);

  const overlap = checkBaseBranchAge(compare, baseChanges, [{ filename: 'pr-standards.mjs' }], config);
  assert.equal(overlap.failures.length, 1, 'overlap must fail, not warn');
  assert.match(overlap.failures[0].got, /pr-standards\.mjs/);

  const raised = checkBaseBranchAge(compare, baseChanges, [], { ...config, maxBaseCommitsBehind: 11 });
  assert.deepEqual(raised, { failures: [], warnings: [] }, 'the threshold is configurable');
  assert.throws(
    () => validateConfig({ ...config, maxBaseCommitsBehind: -1 }),
    ConfigurationError,
    'the configured threshold must be a non-negative integer',
  );
});

test('prevents size-cap escape resurrection', () => {
  // A deletion is not self-enforcing. This keeps stale branches from restoring
  // the escape while leaving every behavioral test green.
  const source = readFileSync(fileURLToPath(new URL('./pr-standards.mjs', import.meta.url)), 'utf8');

  assert.doesNotMatch(source, /oversized-approved/);
  assert.equal(Object.hasOwn(DEFAULT_CONFIG, 'overrideLabel'), false);
  assert.equal(Object.hasOwn(DEFAULT_CONFIG, 'overrideActors'), false);
  assert.equal(checkSize.length, 2);
});

test('enforces rules for chore branches (null issue)', () => {
  assert.equal(validateTitle('Added something', 'cr', null).ok, false);
  assert.equal(validateBody(validBody.replace('bun test -> 214 passed', 'TODO').replace('Closes #142\n\n', ''), null, config).ok, false);
});

test('fails a chore branch with a Closes reference', () => {
  assert.equal(validateBody(validBody, null, config).ok, false);
});

import { main } from './pr-standards.mjs';

const checkerPath = fileURLToPath(new URL('./pr-standards', import.meta.url));
const checkerRoot = path.dirname(checkerPath);

function runDrift(root) {
  const result = spawnSync(process.execPath, [checkerPath, 'drift', '--json'], {
    cwd: root,
    encoding: 'utf8',
  });
  return { ...result, json: JSON.parse(result.stdout) };
}

function driftFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-drift-'));
  fs.mkdirSync(path.join(root, '.github'));
  fs.copyFileSync(path.join(checkerRoot, '.github', 'pr-standards.json'), path.join(root, '.github', 'pr-standards.json'));
  fs.copyFileSync(path.join(checkerRoot, 'AGENTS.md'), path.join(root, 'AGENTS.md'));
  fs.copyFileSync(path.join(checkerRoot, '.github', 'pull_request_template.md'), path.join(root, '.github', 'pull_request_template.md'));
  return root;
}

test('drift accepts this repo’s substituted managed files', () => {
  // The source AGENTS template uses __PREFIX__; the installed block uses scr.
  // This proves the checker substitutes before comparing instead of flagging
  // every adopted repository as stale.
  const result = runDrift(checkerRoot);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(result.json.adopted, true);
  assert.deepEqual(result.json.failures, []);
});

test('drift reports a hand-edited managed block as stale with its diff', () => {
  const root = driftFixture();
  try {
    const agentsPath = path.join(root, 'AGENTS.md');
    fs.writeFileSync(agentsPath, readFileSync(agentsPath, 'utf8').replace(
      'One issue. One PR. One concern. Under 500 counted lines.',
      'One issue can use two pull requests.',
    ));
    const result = runDrift(root);
    const failure = result.json.failures.find((item) => item.check === 'managed AGENTS.md block');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(failure.got, 'stale');
    assert.match(failure.diff, /^--- pr-standards-templates\/agents-block\.md/m);
    assert.match(failure.diff, /^\+\+\+ AGENTS\.md managed block/m);
    assert.match(failure.diff, /\+One issue can use two pull requests\./);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift reports a missing managed block as missing, not stale', () => {
  const root = driftFixture();
  try {
    fs.writeFileSync(path.join(root, 'AGENTS.md'), '# Local instructions\n');
    const result = runDrift(root);
    const failure = result.json.failures.find((item) => item.check === 'managed AGENTS.md block');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(failure.got, 'missing');
    assert.equal(Object.hasOwn(failure, 'diff'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift reports a duplicated managed block as malformed, not a false pass', () => {
  const root = driftFixture();
  try {
    const agentsPath = path.join(root, 'AGENTS.md');
    const current = readFileSync(agentsPath, 'utf8');
    // A leftover stale block after a correct one (hand edit, or a rollout
    // repair that appended fresh content past markers it wouldn't touch)
    // must not be reported as a PASS just because the first pair matches.
    fs.writeFileSync(agentsPath, current + '\n' + current);
    const result = runDrift(root);
    const failure = result.json.failures.find((item) => item.check === 'managed AGENTS.md block');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(failure.got, 'malformed');
    assert.equal(Object.hasOwn(failure, 'diff'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift leaves a repository without config unadopted', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-no-drift-config-'));
  try {
    const result = runDrift(root);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(result.json.adopted, false);
    assert.deepEqual(result.json.failures, []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift prints a human-readable status for a repository without config', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-no-drift-config-human-'));
  try {
    const result = spawnSync(process.execPath, [checkerPath, 'drift'], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /not adopted/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift reports a missing pull request template as missing', () => {
  const root = driftFixture();
  try {
    fs.rmSync(path.join(root, '.github', 'pull_request_template.md'));
    const result = runDrift(root);
    const failure = result.json.failures.find((item) => item.check === 'pull request template');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(failure.got, 'missing');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('drift reports an edited pull request template as stale with its diff', () => {
  const root = driftFixture();
  try {
    const templatePath = path.join(root, '.github', 'pull_request_template.md');
    fs.writeFileSync(templatePath, readFileSync(templatePath, 'utf8').replace(
      'Closes #',
      'Fixes #',
    ));
    const result = runDrift(root);
    const failure = result.json.failures.find((item) => item.check === 'pull request template');
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.equal(failure.got, 'stale');
    assert.match(failure.diff, /^--- pr-standards-templates\/pull_request_template\.md/m);
    assert.match(failure.diff, /^\+\+\+ \.github\/pull_request_template\.md/m);
    assert.match(failure.diff, /\+Fixes #/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

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
    if (url.includes('/compare/')) {
      return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test', sha: 'deadbee' }, base: { ref: 'main' }, title: '[CR-12] Test PR', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
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

test('an exempt branch skips proof of work along with title and body', async () => {
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
    if (url.includes('pulls/13/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Fix the thing' } }]) };
    }
    if (url.includes('pulls/13/files')) {
      // A refactor branch is exempt from title/body, but it still moves real
      // UI files -- that must not trigger the proof-of-work requirement, which
      // depends on a `## How I verified` section this branch was never asked
      // to write.
      return { ok: true, json: async () => ([{ filename: 'src/components/Button.tsx', status: 'modified' }]) };
    }
    if (url.includes('/compare/')) {
      return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('pulls/13')) {
      return { ok: true, json: async () => ({ head: { ref: 'refactor', sha: 'deadbee' }, base: { ref: 'main' }, title: 'Move things around', body: 'no structured body at all' }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '13', '--json']);
    const result = JSON.parse(output);
    assert.equal(result.failures.some(f => f.check === 'proof of a visible change'), false);
    assert.equal(exitCode, 0);
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
    if (url.includes('/compare/')) {
      return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'rmt-12-test', sha: 'deadbee' }, base: { ref: 'main' }, title: '[RMT-12] Test PR that works', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
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
    assert.equal(result.provenance, 'from test/repo .github/pr-standards.json @ main');
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('compares a fork PR by head sha, not by a head branch name the base repo may not have', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';

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
    // A fork PR's head sha does not exist as a branch name in the base repo.
    // Only a compare keyed on the sha can succeed here; one keyed on the
    // ref would 404 or match an unrelated same-named branch in the base repo.
    if (url.includes('/compare/main...forksha123')) {
      return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test', sha: 'forksha123' }, base: { ref: 'main' }, title: '[CR-12] Compare a fork by its head sha', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
    }
    if (url.includes('issues/12')) {
      return { ok: true, json: async () => ({ state: 'open' }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '12', '--json']);
    assert.equal(exitCode, 0);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('a malformed behind_by does not silently skip the branch-age check', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';

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
    // -1 is not a value GitHub should ever send, but a naive `behind_by <=
    // threshold` early return would treat it as "up to date" and skip the
    // check entirely instead of surfacing the bad data.
    if (url.includes('/compare/main...deadbee')) {
      return { ok: true, json: async () => ({ behind_by: -1, merge_base_commit: { sha: '1234567' } }) };
    }
    // Reached only if the malformed behind_by above is mistakenly treated
    // as "in range" and never re-validated.
    if (url.includes('/compare/1234567...main')) {
      return { ok: true, json: async () => ({ commits: [], files: [] }) };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test', sha: 'deadbee' }, base: { ref: 'main' }, title: '[CR-12] Test PR', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
    }
    if (url.includes('issues/12')) {
      return { ok: true, json: async () => ({ state: 'open' }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '12', '--json']);
    assert.equal(exitCode, 1);
    const result = JSON.parse(output);
    assert.equal(result.failures.some((f) => /invalid branch comparison/.test(f.got)), true);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('a stale branch point reaches the base comparison and fails on overlap end to end', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';

  globalThis.fetch = async (url) => {
    if (url.includes('contents/.github/pr-standards.json')) {
      return { ok: true, json: async () => ({ content: Buffer.from(JSON.stringify({ prefix: 'cr' })).toString('base64'), encoding: 'base64' }) };
    }
    if (url.includes('pulls/12/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Fix the thing' } }]) };
    }
    if (url.includes('pulls/12/files')) {
      return { ok: true, json: async () => ([{ filename: 'pr-standards.mjs' }]) };
    }
    // The first compare reports the branch is behind by more than the
    // default threshold, which must trigger the second compare below
    // rather than stopping at this pure-unit-tested decision.
    if (url.includes('/compare/main...deadbee')) {
      return { ok: true, json: async () => ({ behind_by: 11, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('/compare/1234567...main')) {
      return {
        ok: true,
        json: async () => ({
          commits: [{ sha: 'abcdef1', commit: { message: 'Remove the escape hatch' } }],
          files: [{ filename: 'pr-standards.mjs' }],
        }),
      };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test', sha: 'deadbee' }, base: { ref: 'main' }, title: '[CR-12] Test PR', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
    }
    if (url.includes('issues/12')) {
      return { ok: true, json: async () => ({ state: 'open' }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    const exitCode = await main(['pr', '--repo', 'test/repo', '--number', '12', '--json']);
    assert.equal(exitCode, 1);
    const result = JSON.parse(output);
    assert.equal(result.failures.some((f) => f.check === 'branch point overlaps base changes'), true);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('a stale branch point with no overlapping files warns rather than fails end to end', async () => {
  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';

  globalThis.fetch = async (url) => {
    if (url.includes('contents/.github/pr-standards.json')) {
      return { ok: true, json: async () => ({ content: Buffer.from(JSON.stringify({ prefix: 'cr' })).toString('base64'), encoding: 'base64' }) };
    }
    if (url.includes('pulls/12/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Fix the thing' } }]) };
    }
    if (url.includes('pulls/12/files')) {
      return { ok: true, json: async () => ([{ filename: 'README.md' }]) };
    }
    if (url.includes('/compare/main...deadbee')) {
      return { ok: true, json: async () => ({ behind_by: 11, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('/compare/1234567...main')) {
      return {
        ok: true,
        json: async () => ({
          commits: [{ sha: 'abcdef1', commit: { message: 'Remove the escape hatch' } }],
          files: [{ filename: 'pr-standards.mjs' }],
        }),
      };
    }
    if (url.includes('pulls/12')) {
      return { ok: true, json: async () => ({ head: { ref: 'cr-12-test', sha: 'deadbee' }, base: { ref: 'main' }, title: '[CR-12] Warn on a stale branch point', body: validBody.replace('142', '12').replace('142', '12').replace('142', '12') }) };
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
    assert.equal(result.warnings.some((w) => w.check === 'branch point is behind base'), true);
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

test('the managed AGENTS block has the spacing Prettier requires', () => {
  // Prettier reads a comment followed immediately by content as one block and
  // reformats it, so an AGENTS.md written by the rollout failed
  // `prettier --check` and took a repo's whole verify job with it. The blank
  // lines either side of the markers are what keep them separate.
  //
  // The assertions deliberately do not name the block's text. What has to hold
  // is the shape at the two boundaries; pinning the last line of prose as well
  // would fail this test for an edit that changes nothing Prettier cares about.
  const block = readFileSync(new URL('./pr-standards-templates/agents-block.md', import.meta.url), 'utf8');
  const lines = block.trimEnd().split('\n');

  assert.equal(lines[0], '<!-- pr-standards:start -->');
  assert.equal(lines[1], '', 'no blank line after the opening marker');
  assert.notEqual(lines[2].trim(), '', 'the block should start right after one blank line');

  assert.equal(lines.at(-1), '<!-- pr-standards:end -->');
  assert.equal(lines.at(-2), '', 'no blank line before the closing marker');
  assert.notEqual(lines.at(-3).trim(), '', 'the block should end right before one blank line');
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

test('proof: a visible change needs before and after attachments', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const withUrls = (n) => `${validBody}\n` + Array.from({ length: n }, (_, i) =>
    `![shot](https://github.com/user-attachments/assets/abc${i})`).join('\n');
  const proofNa = `${validBody}\nProof: n/a — a type-level refactor with no runtime path`;
  const proofNaShort = `${validBody}\nProof: n/a — no ui`;

  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  assert.equal(failed(checkProof(validBody, uiFiles, config)), true);
  assert.equal(warned(checkProof(withUrls(1), uiFiles, config)), true);
  assert.equal(failed(checkProof(withUrls(1), uiFiles, config)), false);
  assert.equal(failed(checkProof(withUrls(2), uiFiles, config)), false);
  assert.equal(warned(checkProof(withUrls(2), uiFiles, config)), false);

  // A stated reason clears it; "n/a" on its own does not, or the escape hatch
  // becomes the default and the rule stops meaning anything.
  assert.equal(failed(checkProof(proofNa, uiFiles, config)), false);
  assert.equal(failed(checkProof(proofNaShort, uiFiles, config)), true);

  // Nothing visible changed, so nothing has to be shown.
  assert.equal(failed(checkProof(validBody, [{ filename: 'src/server/api.ts', status: 'modified' }], config)), false);
  assert.equal(failed(checkProof(validBody, [{ filename: 'src/components/Button.test.tsx', status: 'modified' }], config)), false);

  assert.equal(isUiFile('src/components/Button.tsx', config), true);
  assert.equal(isUiFile('src/components/Button.test.tsx', config), false);
  assert.equal(hasUiDiff(uiFiles, config), true);
  assert.equal(hasUiDiff([{ filename: 'src/server/api.ts' }], config), false);
});

test('proof: a bare command claim warns that it lives only in the body', () => {
  const nonUiFiles = [{ filename: 'src/server/api.ts', status: 'modified' }];
  const warned = (r) => r.warnings.some((w) => w.check === 'attributable proof');

  // validBody's "How I verified" is `bun test -> 214 passed` and nothing else --
  // exactly the claim that costs nothing to type whether or not it ran.
  assert.equal(warned(checkProof(validBody, nonUiFiles, config)), true);

  // A linked Actions run is something GitHub itself produced.
  const withRun = `${validBody}\nhttps://github.com/pooriaarab/scripts/actions/runs/123456789`;
  assert.equal(warned(checkProof(withRun, nonUiFiles, config)), false);

  // An attachment settles it too, even off the UI path.
  const withAttachment = `${validBody}\n![log](https://github.com/user-attachments/assets/abc)`;
  assert.equal(warned(checkProof(withAttachment, nonUiFiles, config)), false);

  // The documented hatch already carries its own burden -- a stated reason --
  // so it settles this warning the same way it settles the UI one.
  const withHatch = `${validBody}\nProof: n/a — a CLI check with no visible surface at all.`;
  assert.equal(warned(checkProof(withHatch, nonUiFiles, config)), false);

  // Never fails. Most repos in the fleet do not run their own tests in CI yet,
  // so this stays a nudge, not a gate (#85).
  assert.equal(checkProof(validBody, nonUiFiles, config).failures.length, 0);

  // requireProof: false turns this off along with the UI checks -- a repo that
  // opted out of proof entirely has no reason to be warned about how it phrased it.
  assert.equal(warned(checkProof(validBody, nonUiFiles, { ...config, requireProof: false })), false);

  // A run ID immediately followed by more word characters is not a GitHub
  // Actions URL GitHub would ever produce -- it is a numeric prefix wearing a
  // real link's clothes. Without a boundary check after \d+, the digits alone
  // satisfied the pattern and the trailing text rode along for free.
  const withFakeRun = `${validBody}\nhttps://github.com/pooriaarab/scripts/actions/runs/123not-a-run`;
  assert.equal(warned(checkProof(withFakeRun, nonUiFiles, config)), true);

  // `_` and `-` are neither letters nor digits, so the first boundary fix
  // (excluding only [a-zA-Z0-9]) missed both of these (#210). The fix moved to
  // naming what CAN follow a real run ID instead of denying one more character
  // at a time, which closes every shape of this bypass at once.
  const withUnderscoreRun = `${validBody}\nhttps://github.com/pooriaarab/scripts/actions/runs/123_not-a-run`;
  assert.equal(warned(checkProof(withUnderscoreRun, nonUiFiles, config)), true);
  const withHyphenRun = `${validBody}\nhttps://github.com/pooriaarab/scripts/actions/runs/123-not-a-run`;
  assert.equal(warned(checkProof(withHyphenRun, nonUiFiles, config)), true);

  // Sentence punctuation only ends the run ID when it actually ends the
  // clause. Gluing a dot, comma, semicolon, colon, or bang directly onto more
  // text is the same disguised-suffix bypass wearing different punctuation --
  // treating the punctuation as a boundary on its own (without checking what
  // follows it) let all of these through.
  const withGluedPunctuation = [
    'https://github.com/pooriaarab/scripts/actions/runs/123.not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123,not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123;not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123:not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123!not-a-run',
  ];
  for (const shape of withGluedPunctuation) {
    assert.equal(warned(checkProof(`${validBody}\n${shape}`, nonUiFiles, config)), true, shape);
  }

  // A lone `*` glued directly onto the digits is the same disguised-suffix
  // bypass wearing a Markdown emphasis character instead of a dot or comma:
  // it must actually reach whitespace/end-of-string to count as a boundary,
  // not just appear once.
  const withGluedAsterisk = `${validBody}\nhttps://github.com/pooriaarab/scripts/actions/runs/123*not-a-run`;
  assert.equal(warned(checkProof(withGluedAsterisk, nonUiFiles, config)), true);

  // A fake glued on with one of the delimiter characters the boundary check
  // otherwise treats as an ordinary closing character (`)`, `]`, a quote, a
  // backtick) is the same disguised-suffix bypass again: that character must
  // still actually reach whitespace/end-of-string to count as a real close,
  // not just appear once with more text riding along after it.
  const withGluedDelimiter = [
    'https://github.com/pooriaarab/scripts/actions/runs/123)not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123]not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123}not-a-run',
    'https://github.com/pooriaarab/scripts/actions/runs/123"not-a-run',
  ];
  for (const shape of withGluedDelimiter) {
    assert.equal(warned(checkProof(`${validBody}\n${shape}`, nonUiFiles, config)), true, shape);
  }

  // A real run URL still clears the warning in every shape GitHub actually
  // produces: nested under a job, with a query string, with a fragment,
  // inside a markdown link, wrapped in Markdown bold, and followed by
  // ordinary sentence punctuation that actually ends the clause (whitespace
  // or end-of-string after it).
  const realShapes = [
    'https://github.com/pooriaarab/scripts/actions/runs/123456789/job/987654321',
    'https://github.com/pooriaarab/scripts/actions/runs/123456789?check_suite_focus=true',
    'https://github.com/pooriaarab/scripts/actions/runs/123456789#summary',
    '[log](https://github.com/pooriaarab/scripts/actions/runs/123456789)',
    'See https://github.com/pooriaarab/scripts/actions/runs/123456789.',
    'See https://github.com/pooriaarab/scripts/actions/runs/123456789, it passed.',
    // A parenthetical remark that ends in a full sentence closes with the
    // period *inside* the parenthesis, not after it -- the punctuation and
    // the closing delimiter both sit between the run ID and the line's end.
    '(https://github.com/pooriaarab/scripts/actions/runs/123456789.)',
    '[log](https://github.com/pooriaarab/scripts/actions/runs/123456789.)',
    // Markdown bold closes flush against the digits with no separator --
    // the emphasis markers themselves are the boundary here. Underscore
    // emphasis (italics) does the same thing with a different character.
    '**https://github.com/pooriaarab/scripts/actions/runs/123456789**',
    'See **https://github.com/pooriaarab/scripts/actions/runs/123456789** it passed.',
    '_https://github.com/pooriaarab/scripts/actions/runs/123456789_',
    // A curly brace closes the same way a paren or bracket does.
    '{https://github.com/pooriaarab/scripts/actions/runs/123456789}',
  ];
  for (const shape of realShapes) {
    assert.equal(warned(checkProof(`${validBody}\n${shape}`, nonUiFiles, config)), false, shape);
  }

  // requireAttributableProof ratchets the same finding to a failure, for a repo
  // whose own tests run in CI and can always produce a run link.
  const strict = { ...config, requireAttributableProof: true };
  const strictResult = checkProof(validBody, nonUiFiles, strict);
  assert.equal(strictResult.failures.some((f) => f.check === 'attributable proof'), true);
  assert.equal(warned(strictResult), false);
  assert.equal(warned(checkProof(withRun, nonUiFiles, strict)), false);
  assert.equal(checkProof(withRun, nonUiFiles, strict).failures.length, 0);

  // Silent on a UI diff whose visible-change check already failed: that failure
  // already names the missing capture, and two findings for one gap reads as
  // two gaps.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const uiResult = checkProof(validBody, uiFiles, config);
  assert.equal(uiResult.failures.some((f) => f.check === 'proof of a visible change'), true);
  assert.equal(warned(uiResult), false);
  assert.equal(checkProof(validBody, uiFiles, strict).failures.some((f) => f.check === 'attributable proof'), false);
});

test('proof: a rename out of the UI globs still counts as a UI diff', () => {
  // GitHub reports a rename as one file object with both names. Checking only
  // the new name lets a rename that moves a UI file to a non-matching name
  // (or extension) carry along a content change while silently clearing the
  // proof requirement.
  const renamed = [{
    filename: 'src/archive/Home.txt',
    previous_filename: 'src/pages/Home.tsx',
    status: 'renamed',
  }];
  assert.equal(hasUiDiff(renamed, config), true);
  assert.equal(checkProof(validBody, renamed, config).failures.some((f) => f.check === 'proof of a visible change'), true);

  // A rename between two non-UI names is still not a UI diff.
  assert.equal(hasUiDiff([{ filename: 'src/server/api2.ts', previous_filename: 'src/server/api.ts', status: 'renamed' }], config), false);
});

test('proof: media belongs in user-attachments, not in the commit', () => {
  const flagged = [
    'screenshots/home.png', 'screenshot-123/demo.png', 'a/b/screenshots/x.jpg',
    'proof/demo.mp4', 'proof-v2/clip.webm', 'src/before.png',
    'src/component-after.jpg', 'docs/demo-recording.mov',
    'image.png', 'photo.jpeg', 'clip.gif', 'screen.webp',
  ].map((filename) => ({ filename, status: 'added' }));
  for (const file of flagged) {
    assert.equal(isCommittedProofMedia(file), true, `should flag ${file.filename}`);
    const r = checkProof(validBody, [file], config);
    assert.equal(r.failures.some((f) => f.check === 'committed proof media'), true, `checkProof should flag ${file.filename}`);
  }

  // Everything else is a product asset. A repo full of real images must not
  // start failing because one of them is a png.
  for (const filename of [
    'public/logo.png', 'public/assets/bg.jpg', 'src/assets/icon.png', 'assets/image.png', 'src/app/logo.png',
    'public/before.png', 'src/assets/after-signup.png',
  ]) {
    const file = { filename, status: 'added' };
    // Flagging an asset directory rejects honest product work. This is the
    // only fix whose current failure direction is a false failure.
    assert.equal(isCommittedProofMedia(file), false, `should not flag ${filename}`);
    const r = checkProof(validBody, [file], config);
    assert.equal(r.failures.length, 0);
    // validBody's own "How I verified" is a bare command claim with nothing
    // external backing it, so the body-only-proof warning is expected here;
    // what this test cares about is that the asset triggers nothing else.
    assert.equal(r.warnings.every((w) => w.check === 'attributable proof'), true);
  }
  // A proof-named directory UNDER an asset root stays exempt. The precedence is
  // asserted on its own below; the short version is that a screenshot gallery
  // served from public/ is ordinary product work.
  assert.equal(isCommittedProofMedia({ filename: 'public/screenshots/home.png', status: 'added' }), false);

  // Only an added file is suspicious: editing a media file already in the repo
  // is maintenance of a real asset. Treating it as proof media rejects honest
  // work, which is the failure direction fixed here.
  assert.equal(isCommittedProofMedia({ filename: 'screenshots/home.png', status: 'modified' }), false);
  assert.equal(isCommittedProofMedia({ filename: 'screenshots/home.png', status: 'renamed' }), false);
  assert.equal(isCommittedProofMedia({ filename: 'src/before.png' }), true);
  assert.equal(isCommittedProofMedia({ filename: 'screenshots/readme.txt', status: 'added' }), false);
});

test('proof: only requireProof clears the checks, and no label can', () => {
  // #114 removed the size cap's override label because an agent can apply its
  // own label. The same argument applies here, so there is no proof label at
  // all: a requirement an agent can waive is not a requirement. requireProof is
  // a config decision that lives in the repo and shows up in a diff.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const media = [{ filename: 'screenshots/home.png', status: 'added' }];

  assert.equal(checkProof(validBody, [...uiFiles, ...media], config).failures.length > 0, true);

  const off = { ...config, requireProof: false };
  assert.equal(checkProof(validBody, [...uiFiles, ...media], off).failures.length, 0);

  // A label named like the old escape hatch changes nothing, because nothing
  // reads labels any more.
  assert.equal(DEFAULT_CONFIG.proofOverrideLabel, undefined);
});

test('proof media path rules stay separated by kind', () => {
  const source = readFileSync(new URL('./pr-standards.mjs', import.meta.url), 'utf8');

  // Mixing directory and filename rules makes a future exemption easy to
  // misapply. That can reject honest work or let weak evidence through.
  assert.match(source, /const PROOF_MEDIA_DIR_GLOBS = \[/);
  assert.match(source, /const PROOF_MEDIA_NAME_GLOBS = \[/);
  assert.doesNotMatch(source, /const PROOF_MEDIA_GLOBS = \[/);
});

test('the documented proof hatch is not a refusal to answer', () => {
  // The two rules this feature adds contradicted each other. checkProof accepts
  // `Proof: n/a — <reason>` and the docs say to write it under How I verified;
  // validateBody rejected any N/A in that section. So a change with no visible
  // surface could not pass at all, written exactly where it was told to write
  // it. Found by hitting it on this feature's own pull request.
  const section = (...lines) => [
    'Closes #64', '', '## What', 'One sentence.', '', '## Why', 'Because.', '',
    '## How I verified', ...lines, '', 'Assisted-by: agent:model',
  ].join('\n');
  const cfg = { ...DEFAULT_CONFIG, prefix: 'scr' };
  const evidence = '$ node --test pr-standards.test.mjs\ntests 43 / pass 43 / fail 0';

  assert.equal(validateBody(section(evidence, '', 'Proof: n/a — a checker with no user-visible surface'), 64, cfg).ok, true);

  // A bare refusal still fails, which is what the guard is for.
  for (const refusal of ['N/A', 'n/a', 'TODO', 'tested locally', 'Proof: n/a']) {
    assert.equal(validateBody(section(evidence, '', refusal), 64, cfg).ok, false, `${refusal} should still fail`);
  }
});

test('proof: the same image pasted twice is one image', () => {
  // The threshold asks for before AND after, not for two links. Counting raw
  // matches let one screenshot pasted twice clear it, which is the loophole the
  // whole check exists to close.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  assert.equal(warned(checkProof(`${validBody}\n${url('abc')}\n${url('abc')}`, uiFiles, config)), true);
  // Nor does a query string on the same asset make it a second one.
  assert.equal(warned(checkProof(`${validBody}\n${url('abc')}\n${url('abc?raw=1')}`, uiFiles, config)), true);
  // Two genuinely different assets clear it.
  assert.equal(warned(checkProof(`${validBody}\n${url('abc')}\n${url('def')}`, uiFiles, config)), false);
  // Nor does trailing prose punctuation on a bare URL make it a second one:
  // the markdown embed stops at the closing paren, but a bare URL followed by
  // a period in a sentence keeps that period as part of the match.
  const bare = (id) => `https://github.com/user-attachments/assets/${id}`;
  assert.equal(warned(checkProof(`${validBody}\nBefore: ${bare('abc')}. After: ${url('abc')}`, uiFiles, config)), true);
});

test('proof: documented placeholders are not attachments', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const body = validBody
    + '\n![before](https://github.com/user-attachments/assets/<before>)'
    + '\n![after](https://github.com/user-attachments/assets/<after>)';

  // Counting angle-bracketed placeholders lets weak, copy-pasted evidence
  // through. The failure direction is weak evidence accepted.
  assert.equal(failed(checkProof(body, uiFiles, config)), true);
});

test('proof: inline-code URLs deduplicate with embedded URLs', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => 'https://github.com/user-attachments/assets/' + id;
  const backtick = String.fromCharCode(96);
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');
  const body = validBody
    + '\n![shot](' + url('abc') + ')'
    + '\nAlso see ' + backtick + url('abc') + backtick + '.';

  // Treating backticks as URL data turns one asset into two ids and lets weak
  // evidence through. The failure direction is weak evidence accepted.
  assert.equal(failed(checkProof(body, uiFiles, config)), false);
  assert.equal(warned(checkProof(body, uiFiles, config)), true);
});

test('proof: attachments only count inside How I verified', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const embeds = [
    '![before](https://github.com/user-attachments/assets/abc)',
    '![after](https://github.com/user-attachments/assets/def)',
  ].join('\n');
  const section = (verified, extraWhat = '') => [
    'Closes #142', '', '## What',
    `Fixes the onboarding drop-off after step three.${extraWhat}`, '',
    '## Why', 'Issue #142 reports that users lose their progress at this step. This change keeps the progress state.', '',
    '## How I verified', verified, '', 'Assisted-by: claude-personal:claude-opus-5',
  ].join('\n');

  // The docs say the embeds live under How I verified, so that is where the
  // check reads. Two real embeds pasted under What instead must not satisfy it.
  assert.equal(failed(checkProof(section('bun test -> 214 passed', `\n${embeds}`), uiFiles, config)), true);
  assert.equal(failed(checkProof(section(`bun test -> 214 passed\n${embeds}`), uiFiles, config)), false);
});

test('proof: the body reader follows rendered Markdown fences', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const failed = (result) => result.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (result) => result.warnings.some((w) => w.check === 'proof of a visible change');
  const body = (...lines) => [
    '## What', 'x', '## Why', 'y', '## How I verified', 'bun test -> pass',
    ...lines,
  ].join('\n');
  const hatch = 'Proof: n/a — a checker with no user-visible surface at all';

  // A closer uses the same character and may be longer than its opener.
  assert.equal(failed(checkProof(body('```', url('aaa'), url('bbb'), '````'), uiFiles, config)), true);
  assert.equal(failed(checkProof(body('```', 'example', '````', hatch), uiFiles, config)), false);
  // A different fence character does not close the block.
  assert.equal(failed(checkProof(body('```', '~~~', hatch), uiFiles, config)), true);

  // The two callers answer an unmatched fence in opposite directions.
  assert.equal(failed(checkProof(body('```', url('aaa'), url('bbb')), uiFiles, config)), false);
  assert.equal(failed(checkProof(body('```', hatch), uiFiles, config)), true);

  // Fences opened after list markers and inside blockquotes hide quoted URLs.
  assert.equal(failed(checkProof(body('- ```', `  ${url('aaa')}`, `  ${url('bbb')}`, '  ```'), uiFiles, config)), true);
  assert.equal(failed(checkProof(body('> ```', `> ${url('aaa')}`, `> ${url('bbb')}`, '> ```'), uiFiles, config)), true);
  // A quote container ending also ends its fence, so real proof below it stays visible.
  assert.equal(failed(checkProof(body('> ```', '> quoted example', url('ccc'), url('ddd')), uiFiles, config)), false);

  // CRLF must not make a valid closing fence look unterminated.
  const crlfBody = body('```', url('eee'), url('fff'), '```', 'trailer').replaceAll('\n', '\r\n');
  assert.equal(failed(checkProof(crlfBody, uiFiles, config)), true);

  // Four spaces mark indented code, not a fenced block. This leaves one real URL,
  // which warns instead of failing, and distinguishes the two interpretations.
  const indented = body('    ```', url('ggg'), '    ```');
  assert.equal(failed(checkProof(indented, uiFiles, config)), false);
  assert.equal(warned(checkProof(indented, uiFiles, config)), true);

  // A closer's indentation tolerance is always <=3 outside a list item, not
  // <=3 beyond the opener's own indentation -- a 6-space line never closes a
  // 3-space fence, so the hatch below it stays hidden inside it.
  assert.equal(failed(checkProof(body('   ```', '      ```', hatch), uiFiles, config)), true);

  // A backtick fence cannot carry a backtick in its info string; GitHub reads
  // that line as plain text, never an opener, so an unrelated hatch below an
  // info string like this is not swallowed by a fence that was never real.
  assert.equal(failed(checkProof(body('```` `weird`', hatch), uiFiles, config)), false);

  // A closer line that is itself quoted does not close a fence that opened
  // outside any blockquote -- GitHub renders "> ```" as literal content
  // inside the still-open fence, not as a container the fence closes within.
  // The fence stays unterminated, so both callers answer it as they answer
  // any other unmatched fence.
  assert.equal(failed(checkProof(body('```', url('aaa'), url('bbb'), '> ```'), uiFiles, config)), false);
  assert.equal(failed(checkProof(body('```', 'some code', '> ```', hatch), uiFiles, config)), true);
});

test('proof: the body reader keeps HTML comments separate from fences', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const failed = (result) => result.failures.some((f) => f.check === 'proof of a visible change');
  const body = (...lines) => [
    '## What', 'x', '## Why', 'y', '## How I verified', 'bun test -> pass',
    ...lines,
  ].join('\n');

  // An escaped marker is visible Markdown, so its attachments count.
  assert.equal(failed(checkProof(body(`\\<!-- ${url('aaa')} ${url('bbb')} -->`), uiFiles, config)), false);
  // A fence marker inside a comment is comment text, not a real fence.
  assert.equal(failed(checkProof(body('<!-- example:', '```', '-->', url('ccc'), url('ddd')), uiFiles, config)), false);
  // Backslashes escape in pairs -- two of them render as one literal
  // backslash, leaving the marker live, so the comment still hides its URLs.
  assert.equal(failed(checkProof(body(`\\\\<!-- ${url('eee')} ${url('fff')} -->`), uiFiles, config)), true);
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

test('bunx counts as a command, like npx already did', () => {
  // Alternation is first-match, so `bun` won on the string "bunx" and then the
  // trailing \b failed against the `x`. The rule therefore rejected the default
  // runner of every bun repo while accepting `npx`, and the failure message
  // said only "a command and its result", naming nothing. A real pull request
  // whose evidence was a genuine `bunx prettier --check` run was failed by it.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');

  assert.equal(fails('bunx vitest run -> 214 passed'), false);
  assert.equal(fails('bunx prettier --check docs/a.md -> clean'), false);
  // npx kept working.
  assert.equal(fails('npx prettier --check docs/a.md -> clean'), false);
  // bun itself kept working.
  assert.equal(fails('bun test -> 214 passed'), false);
  // The word boundary still does its original job: a word that merely starts
  // with a command name is not a command.
  assert.equal(fails('Bundle was verified'), true);
  assert.equal(fails('bunxx frobnicate -> 3 passed'), true);
});

test('python3 counts as a command, like pytest already did', () => {
  // The checker itself shells to `python3`, three of its test suites are
  // `python3` scripts, and the workflow templates parse JSON with `python3`,
  // but the command list named none of that. A pull request whose evidence
  // was a genuine `python3 build-repo-prefixes.test.py` run failed the rule,
  // and the author answered by putting a pointless `node -e` in front of the
  // command that had already run. A check easier to game than to satisfy
  // trains everyone to game it.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');

  // The workflow's own CI line, with unittest's real output under it.
  assert.equal(fails('python3 build-repo-prefixes.test.py\nOK'), false);
  // Same for the other spelling, and for a command the author actually ran.
  assert.equal(fails('python install-pr-hooks.test.py\nOK'), false);
  // The `$` prompt prefix is already stripped before the command check.
  assert.equal(fails('$ python3 -c "import json, sys; json.load(open(\'repo-prefixes.json\')); print(\'OK\')"\nOK'), false);
  // The rule is a command AND its result: a `python3` line with no result
  // still fails, exactly like a bare `node --test` would.
  assert.equal(fails('python3 build-repo-prefixes.test.py'), true);
  // The word boundary still ends the command name: a sentence about pythonic
  // style, even with a result beside it, names no command.
  assert.equal(fails('Pythonic naming reads better -> 3 passed'), true);
  assert.equal(fails('The pythonic idiom was verified'), true);
});

test('bash is a command, and real tool output is a result', () => {
  // The command list named node and python3 and missed the runner a shell-script
  // suite actually uses. PR #205 recorded `bash worker-run.test.sh` and failed
  // this check. The result vocabulary missed the strings those tools print when
  // they succeed. Both halves produced the same message, so the author could
  // not tell which to fix.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');
  const finding = (text) => validateBody(body(text), 142, config)
    .failures.find((f) => f.check === '## How I verified');

  assert.equal(fails('bash tests/x.sh\nResults: 13 passed, 0 failed'), false, 'bash is a command');
  assert.equal(fails('sh -c ./run.sh\nResults: 13 passed, 0 failed'), false, 'sh is a command');
  assert.equal(fails('docker build .\nSuccessfully built'), false, 'docker is a command');
  assert.equal(fails('curl -sSf http://127.0.0.1:8080/health\nok'), false, 'curl is a command');
  assert.equal(fails('terraform plan\nNo changes.'), false, 'terraform is a command');
  assert.equal(fails('./script.sh\nFound 0 warnings'), false, './script is a command');

  assert.equal(fails('bunx oxlint@^1\nFound 0 warnings'), false, 'Found 0 warnings is a result');

  // A count that means clean is zero, not any number. Widening the result
  // vocabulary to `\d+ warnings` would let a red run through while the body
  // still read as verified -- which is worse than the narrow rule this
  // replaces, because the failure would be invisible rather than loud.
  assert.equal(fails('bunx oxlint@^1\nFound 7 warnings'), true, '7 warnings is not a result');
  assert.equal(fails('npx tsc --noEmit\n3 errors'), true, '3 errors is not a result');
  // oxlint's real format prints both counts on one line. A nonzero warning
  // count must not be masked by a clean "0 errors" alongside it.
  assert.equal(fails('bunx oxlint@^1\nFound 7 warnings and 0 errors'), true, 'a nonzero warning count fails even next to 0 errors');
  assert.equal(fails('python3 install-pr-hooks --apply\ninstalled=1 failed=2'), true, 'failed=2 is not a result');
  assert.equal(fails('python3 install-pr-hooks --selfcheck\ninstalled=1 failed=0'), false, 'failed=0 is a result');
  // The nonzero veto must not read a count across a `key=value` boundary: the
  // 1 in `installed=1` counts installs, not failures.
  assert.equal(fails('bunx x\n12 passed, 2 failed'), true, 'a nonzero failed count still vetoes');
  assert.equal(fails('bunx x\nFound 7 warnings and 0 errors'), true, 'a clean errors count cannot mask warnings');
  assert.equal(fails('npx tsc --noEmit\n0 errors'), false, '0 errors is a result');
  assert.equal(fails('pytest -q\n12 passed'), false, 'pytest still counts');
  assert.equal(fails('cargo test\n14 passed'), false, 'cargo still counts');

  // Widening must not empty the rule. This phrase is the documented refusal.
  assert.equal(fails('Tested locally.'), true);

  const commandOnly = finding('$ bash x.sh\nit did a thing');
  assert.ok(commandOnly, 'a command with no result still fails');
  assert.match(commandOnly.expected, /result/i);
  assert.doesNotMatch(commandOnly.expected, /a command and its result/i);

  const resultOnly = finding('Results: 13 passed, 0 failed');
  assert.ok(resultOnly, 'a result with no command still fails');
  assert.match(resultOnly.expected, /command/i);
  assert.doesNotMatch(resultOnly.expected, /a command and its result/i);
});

test('a nonzero failed count is not masked by "passed" in the same result', () => {
  // "12 passed, 2 failed" matches `pass(?:ed)?` on its own, the same way
  // "Found 7 warnings and 0 errors" matched a clean "0 errors" until the
  // prior fix. A nonzero failure count next to a passing word is still a
  // red run, in either spelling this repo's tools use.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');

  assert.equal(fails('pytest -q\n12 passed, 2 failed'), true, '2 failed is not a result, even beside "passed"');
  assert.equal(fails('bash tests/x.sh\n13 passed, 0 failed'), false, '0 failed stays a passing result');
  assert.equal(fails('python3 install-pr-hooks --apply\ninstalled=1 failed=0 failed=2'), true, 'a later failed=2 is not masked by an earlier failed=0');
});

test('a count is not always spelled with the noun right against it', () => {
  // go test prints "1 test failed", not "1 failed" -- the noun sits between
  // the digit and the word the veto looks for. A count is also not always
  // written without a leading zero. Neither should let a red run through.
  const body = (verified) => [
    '## What', 'One sentence.',
    '## Why', 'Because of the reason.',
    '## How I verified', verified,
    'Assisted-by: agent:model',
  ].join('\n\n');
  const fails = (text) => validateBody(body(text), 142, config)
    .failures.some((f) => f.check === '## How I verified');

  assert.equal(fails('go test ./...\n13 passed, 1 test failed'), true, 'a noun between the count and "failed" still vetoes');
  assert.equal(fails('go test ./...\n11 passed, 2 tests failed'), true, 'the plural noun still vetoes');
  assert.equal(fails('pytest -q\n13 passed, 02 failed'), true, 'a leading zero does not hide a nonzero count');
  assert.equal(fails('python3 install-pr-hooks --apply\ninstalled=1 failed=02'), true, 'a leading zero in a key=value count still vetoes');
  assert.equal(fails('go test ./...\n13 passed, 0 tests failed'), false, 'an all-zero count with a noun stays a passing result');
});

test('prefix precedence holds on the CI path, not only in loadConfig', async () => {
  // #101 fixed the precedence and covered it through loadConfig, which is the
  // LOCAL path. The path that was broken is this one: runPr -> fetchRemoteConfig.
  // The registry had tests; it had none on the path that reads it in CI, and
  // that is exactly how the bug survived long enough to reject an adoption
  // branch the rollout had just created.
  //
  // A repo that states a prefix has decided, so its own config outranks the
  // registry. The registry outranks derivation, because derivation is a guess
  // and the registry is the fleet's answer. Nothing may outrank the config.
  const registry = JSON.parse(readFileSync(new URL('./repo-prefixes.json', import.meta.url), 'utf8'));
  // Only a repo whose registry prefix differs from its derived one can tell the
  // three sources apart.
  const mismatch = Object.entries(registry).find(([n, p]) => derivePrefix(n) !== p);
  assert.ok(mismatch, 'repo-prefixes.json has no entry whose prefix differs from its derived one');
  const [name, registered] = mismatch;

  const originalWrite = process.stdout.write;
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';

  const run = async (configBody, branch) => {
    let output = '';
    process.stdout.write = (chunk) => { output += chunk; return true; };
    globalThis.fetch = async (url) => {
      if (url.includes('contents/.github/pr-standards.json')) {
        return configBody
          ? { ok: true, json: async () => ({ content: Buffer.from(configBody).toString('base64'), encoding: 'base64' }) }
          : { ok: false, status: 404, text: async () => 'Not Found' };
      }
      if (url.includes('/commits')) return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Do one thing' } }]) };
      if (url.includes('/files')) return { ok: true, json: async () => ([]) };
      if (url.includes('/compare/')) return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
      if (url.match(/pulls\/\d+$/)) {
        return { ok: true, json: async () => ({ head: { ref: branch, sha: 'deadbee' }, base: { ref: 'main' }, title: 'x', body: 'x', labels: [] }) };
      }
      if (url.includes('issues/')) return { ok: true, json: async () => ({ state: 'open' }) };
      throw new Error(`Unexpected fetch URL: ${url}`);
    };
    try {
      await main(['pr', '--repo', `pooriaarab/${name}`, '--number', '7', '--json']);
      return JSON.parse(output);
    } finally { process.stdout.write = originalWrite; }
  };

  try {
    // No config: the registry answers, and its branch is accepted.
    const fromRegistry = await run(null, `${registered}-7-do-one-thing`);
    assert.equal(fromRegistry.failures.some((f) => f.check === 'branch name'), false);
    // ...and the derived guess is now rejected, where it used to be the only
    // thing accepted.
    const derivedBranch = await run(null, `${derivePrefix(name)}-7-do-one-thing`);
    assert.equal(derivedBranch.failures.some((f) => f.check === 'branch name'), true);
    // A config prefix outranks the registry.
    const fromConfig = await run(JSON.stringify({ prefix: 'zzz' }), 'zzz-7-do-one-thing');
    assert.equal(fromConfig.failures.some((f) => f.check === 'branch name'), false);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('a served asset root is never committed proof media', () => {
  // Precedence, not just membership. A screenshot gallery under public/ is an
  // ordinary product pattern -- a docs site or a landing page -- so the asset
  // root has to win over the proof-directory signal. Flagging one rejects
  // honest work, and that is the direction this check must not be wrong in.
  // Someone committing pull request media puts it at the repo root or in
  // proof/, not under a directory the site serves.
  const added = (filename) => isCommittedProofMedia({ filename, status: 'added' });

  for (const path of [
    'public/before.png', 'public/screenshots/hero-shot.png',
    'public/images/screenshots/tour-1.png', 'apps/web/assets/screenshots/x.png',
    'apps/web/assets/after.png',
  ]) {
    assert.equal(added(path), false, `${path} is a product asset`);
  }

  // Outside an asset root the signals still fire.
  for (const path of ['screenshots/home.png', 'proof/before.png', 'before.png', 'docs/after.png']) {
    assert.equal(added(path), true, `${path} looks like committed proof media`);
  }
});

test('proof: an attachment under a bullet is not inert', () => {
  // Four leading spaces mark an indented code block only OUTSIDE a list.
  // Inside one they are continuation content that renders normally, so a
  // line-start indentation test rejected an attachment written under a bullet
  // -- an ordinary way to caption before and after, and honest work.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');
  const body = (...lines) => [
    '## What', 'x', '## Why', 'y', '## How I verified', 'bun test -> pass',
    ...lines, 'Assisted-by: agent:model',
  ].join('\n');

  const underBullet = body('- captured both states:', '', `    ${url('aaa')}`, `    ${url('bbb')}`);
  assert.equal(failed(checkProof(underBullet, uiFiles, config)), false);
  assert.equal(warned(checkProof(underBullet, uiFiles, config)), false);

  // An indented URL outside a list is inert on GitHub and still counts here.
  // Telling the two apart needs real block containment, which belongs to the
  // body reader; counting it is the fail-open direction and is deliberate.
  const indented = body(`    ${url('ccc')}`, `    ${url('ddd')}`);
  assert.equal(failed(checkProof(indented, uiFiles, config)), false);
});

test('--prefix judges a branch belonging to another repo', () => {
  // The PreToolUse guard runs in the session's working directory while
  // `gh pr create --repo X` targets X. Without an explicit prefix the branch is
  // checked against the wrong repo and a conforming cross-repo PR is refused.
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-crossrepo-'));
  try {
    const launcher = fileURLToPath(new URL('./pr-standards', import.meta.url));
    const run = (args, env = {}) => spawnSync(process.execPath, [launcher, ...args], {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GITHUB_REPOSITORY: 'pooriaarab/content-rabbit', ...env },
    });

    const crossRepo = run(['precheck', '--branch', 'scr-173-define-the-issue-standard',
      '--title', '[SCR-173] Define the issue standard', '--prefix', 'scr']);
    assert.equal(crossRepo.status, 0, crossRepo.stdout + crossRepo.stderr);
    assert.match(crossRepo.stdout, /Using prefix: scr \(from --prefix\)/);

    // The same branch without the flag is judged against the cwd's repo, which
    // is the bug this flag exists to fix. Asserted so a regression is visible.
    const withoutFlag = run(['precheck', '--branch', 'scr-173-define-the-issue-standard']);
    assert.notEqual(withoutFlag.status, 0, withoutFlag.stdout + withoutFlag.stderr);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('--prefix narrows the check, it never widens it', () => {
  // A flag that lets a caller choose the prefix could be used to wave a bad
  // branch through. It must still refuse a branch that does not match the
  // prefix it was given, and refuse a prefix that is not a valid prefix.
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'prs-prefixguard-'));
  try {
    const launcher = fileURLToPath(new URL('./pr-standards', import.meta.url));
    const run = (args) => spawnSync(process.execPath, [launcher, ...args], {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GITHUB_REPOSITORY: 'pooriaarab/content-rabbit' },
    });

    const mismatch = run(['precheck', '--branch', 'cr-173-x', '--prefix', 'scr']);
    assert.notEqual(mismatch.status, 0, mismatch.stdout + mismatch.stderr);

    // Exit 2 is the configuration-error code.
    assert.equal(run(['precheck', '--branch', 'scr-1-x', '--prefix', 'SCRIPTS']).status, 2);
    assert.equal(run(['precheck', '--branch', 'scr-1-x', '--prefix', 'toolong']).status, 2);

    // The flag belongs to precheck alone; the other modes know their repo.
    assert.equal(run(['branch', '--prefix', 'scr']).status, 2);
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
});

test('a Proof n/a hatch inside an HTML comment is not an answer', () => {
  // hasValidProofNa called a reader that no longer existed, so every proof
  // check threw ReferenceError. It must scan the section it is handed, and it
  // must not accept a hatch that is commented out.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const body = (hatch) => ['## What', 'x', '## Why', 'y', '## How I verified', 'bun test -> pass', hatch].join('\n');
  const reason = 'Proof: n/a — a checker with no user-visible surface at all';
  assert.equal(failed(checkProof(body(reason), uiFiles, config)), false);
  assert.equal(failed(checkProof(body(`<!-- ${reason} -->`), uiFiles, config)), true);
});

test('proof: the body reader keeps what renders around a comment', () => {
  // Three cases the fence/comment tests did not reach. Each one hid or exposed
  // the wrong thing, and each fails against the first version of the reader.
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');
  const body = (...lines) => [
    '## What', 'x', '## Why', 'y', '## How I verified', 'bun test -> pass',
    ...lines,
  ].join('\n');
  const hatch = 'Proof: n/a — a checker with no user-visible surface at all';

  // An unterminated comment hides what follows it, not what precedes it on the
  // same line. GitHub still renders the text before the marker.
  assert.equal(failed(checkProof(body(`${hatch} <!-- leftover`), uiFiles, config)), false);
  assert.equal(failed(checkProof(body(`${url('aaa')} ${url('bbb')} <!--`), uiFiles, config)), false);

  // Every comment on a line is resolved, not just the first. Here only `aaa`
  // renders, so this is one image and warns rather than clearing the pair.
  const two = checkProof(body(`see <!-- x --> ${url('aaa')} <!-- ${url('bbb')} -->`), uiFiles, config);
  assert.equal(failed(two), false);
  assert.equal(warned(two), true);

  // A fence opened inside a blockquote ends with the quote container, so a
  // hatch written after the quote is visible rather than swallowed.
  assert.equal(failed(checkProof(body('> ```', '> example', hatch), uiFiles, config)), false);
});

test('a line moved verbatim between files counts zero', () => {
  // The relocation that surfaced this: text leaves one file and arrives
  // unchanged in another, so the PR authored nothing and used to be billed for
  // it twice. See pooriaarab/scripts#299.
  const body = ['alpha one', 'beta two', 'gamma three'];
  const summary = summarizeFiles([
    { filename: 'src/big.md', additions: 0, deletions: 3, patch: body.map((l) => `-${l}`).join('\n') },
    { filename: 'src/refs/part.md', additions: 3, deletions: 0, patch: body.map((l) => `+${l}`).join('\n') },
  ], config);
  assert.equal(summary.movedLines, 3);
  assert.equal(summary.grossCountedLines, 6);
  assert.equal(summary.countedLines, 0);
});

test('a line changed during a move still counts', () => {
  // The anti-gaming property. Byte equality is the whole test, so editing while
  // moving is billed for the edit.
  const summary = summarizeFiles([
    { filename: 'src/big.md', additions: 0, deletions: 3, patch: '-alpha one\n-beta two\n-gamma three' },
    { filename: 'src/refs/part.md', additions: 3, deletions: 0, patch: '+alpha one\n+beta TWO\n+gamma three' },
  ], config);
  assert.equal(summary.movedLines, 2);
  assert.equal(summary.countedLines, 6 - 4);
});

test('a plain addition is not discounted', () => {
  const summary = summarizeFiles([
    { filename: 'src/new.md', additions: 3, deletions: 0, patch: '+alpha one\n+beta two\n+gamma three' },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 3);
});

test('a rewrite of the same size is not discounted', () => {
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 3, deletions: 3, patch: '-old one\n-old two\n-old three\n+new one\n+new two\n+new three' },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 6);
});

test('a missing patch blocks the discount rather than granting it', () => {
  // GitHub omits `patch` for very large or binary files. Without it the move
  // cannot be proven, so it is not discounted. Silently discounting what the
  // checker could not read would be the worse failure.
  const summary = summarizeFiles([
    { filename: 'src/big.md', additions: 0, deletions: 3, patch: '-alpha one\n-beta two\n-gamma three' },
    { filename: 'src/huge.md', additions: 3, deletions: 0 },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 6);
});

test('an excluded file cannot fund a discount', () => {
  // Generated output is not counted, so it must not cancel counted lines
  // either -- otherwise deleting a lockfile line would pay for a source line.
  const summary = summarizeFiles([
    { filename: 'dist/app.js', additions: 0, deletions: 3, patch: '-alpha one\n-beta two\n-gamma three' },
    { filename: 'src/app.js', additions: 3, deletions: 0, patch: '+alpha one\n+beta two\n+gamma three' },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 3);
});

test('a line removed and re-added in the same file is not a move', () => {
  // The discount is for a RELOCATION -- content leaving one file for another.
  // A line reordered within a single file is not that, and matching it there
  // would let two unrelated same-file edits net out to zero merely for
  // sharing a common line (a blank line, a closing brace, a Markdown rule).
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 1, deletions: 1, patch: '-alpha one\n+alpha one' },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 2);
});

test('a line moved out of a file and a different line moved in still cancel correctly', () => {
  // Three files, so the match must pick partners across files without ever
  // pairing a file with itself, even when that file has both a removal and
  // an addition of lines that also appear elsewhere.
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 1, deletions: 1, patch: '-shared\n+only-in-a' },
    { filename: 'src/b.md', additions: 0, deletions: 1, patch: '-only-in-a' },
    { filename: 'src/c.md', additions: 1, deletions: 0, patch: '+shared' },
  ], config);
  assert.equal(summary.movedLines, 2);
  assert.equal(summary.countedLines, 4 - 4);
});

test('a patch line beginning with a second + or - is not mistaken for a diff header', () => {
  // GitHub's per-file `patch` never carries `---`/`+++` file headers (the
  // filename is already a separate field), so a content line that happens to
  // start with `++` or `--` -- an increment statement, a Markdown rule or
  // frontmatter delimiter -- must still be read as real content once
  // diff-prefixed to `+++i;` or `----`.
  const summary = summarizeFiles([
    { filename: 'src/old.md', additions: 0, deletions: 1, patch: '----' },
    { filename: 'src/new.md', additions: 1, deletions: 0, patch: '+---' },
  ], config);
  assert.equal(summary.movedLines, 1);
  assert.equal(summary.countedLines, 0);
});

test('a patchless added file backfills its blob and still proves a move', async () => {
  // The motivating case (agents-private#170) was a MODIFIED file too large
  // for GitHub to attach a patch to. The other side of a move -- a brand-new
  // file that is just as large -- gets the same treatment from GitHub, and
  // used to be skipped outright because backfill excluded `added`/`removed`
  // status. An `added` file has no base blob to fetch; the fix is to treat
  // that side as empty, not to give up on the file.
  const originalPath = process.env.PATH;
  const originalToken = process.env.GITHUB_TOKEN;
  const originalFetch = globalThis.fetch;
  const originalWrite = process.stdout.write;
  process.env.PATH = '';
  process.env.GITHUB_TOKEN = 'test-token';
  process.env.GITHUB_REPOSITORY = 'other/repo';
  let output = '';
  process.stdout.write = (chunk) => { output += chunk; return true; };

  globalThis.fetch = async (url) => {
    if (url.includes('contents/.github/pr-standards.json')) {
      return { ok: false, status: 404, text: async () => 'Not Found' };
    }
    if (url.includes('pulls/21/commits')) {
      return { ok: true, json: async () => ([{ sha: 'abc1234', commit: { message: 'Move the guide' } }]) };
    }
    if (url.includes('pulls/21/files')) {
      return { ok: true, json: async () => ([
        { filename: 'src/old.md', status: 'modified', additions: 0, deletions: 3, patch: '-line one\n-line two\n-line three' },
        { filename: 'docs/new.md', status: 'added', additions: 3, deletions: 0 },
      ]) };
    }
    if (url.includes('/compare/')) {
      return { ok: true, json: async () => ({ behind_by: 0, merge_base_commit: { sha: '1234567' } }) };
    }
    if (url.includes('contents/docs/new.md')) {
      return { ok: true, json: async () => ({ encoding: 'base64', content: Buffer.from('line one\nline two\nline three').toString('base64') }) };
    }
    if (url.match(/pulls\/21$/)) {
      return { ok: true, json: async () => ({ head: { ref: 'refactor', sha: 'headsha1' }, base: { ref: 'main', sha: 'basesha1' }, title: 'x', body: 'x', labels: [] }) };
    }
    throw new Error(`Unexpected fetch URL: ${url}`);
  };

  try {
    await main(['pr', '--repo', 'test/repo', '--number', '21', '--json']);
    const result = JSON.parse(output);
    assert.equal(result.size.movedLines, 3);
    assert.equal(result.size.countedLines, 0);
  } finally {
    process.stdout.write = originalWrite;
    process.env.PATH = originalPath;
    process.env.GITHUB_TOKEN = originalToken;
    globalThis.fetch = originalFetch;
    delete process.env.GITHUB_REPOSITORY;
  }
});

test('multiset difference keeps duplicates that the other side lacks', () => {
  // The blob fallback derives a patch from this alone, with no diff algorithm:
  // what left a file is base minus head, what arrived is head minus base.
  // Duplicates have to survive, or a file that legitimately repeats a line
  // would look like it lost one.
  assert.deepEqual(multisetDifference(['a', 'b', 'a', 'c'], ['a', 'c']), ['b', 'a']);
  assert.deepEqual(multisetDifference(['a'], ['a', 'a']), []);
  assert.deepEqual(multisetDifference([], ['a']), []);
  assert.deepEqual(multisetDifference(['x', 'x'], []), ['x', 'x']);
});

test('a move through a file that also reorders is fully matched', () => {
  // A(-x), B(-x,+x), C(+x): two real relocations, A->B and B->C. A greedy pass
  // over file order pairs B's addition with A's removal first and then cannot
  // place B's own removal, since same-file pairs are forbidden -- reporting 1
  // where 2 are provable, and undercounting the discount.
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 0, deletions: 1, patch: '-x' },
    { filename: 'src/b.md', additions: 1, deletions: 1, patch: '-x\n+x' },
    { filename: 'src/c.md', additions: 1, deletions: 0, patch: '+x' },
  ], config);
  assert.equal(summary.movedLines, 2);
});

test('a reorder inside one file matches nothing', () => {
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 3, deletions: 3, patch: '-x\n-y\n-z\n+z\n+y\n+x' },
  ], config);
  assert.equal(summary.movedLines, 0);
  assert.equal(summary.countedLines, 6);
});

test('the smaller side caps the match', () => {
  const summary = summarizeFiles([
    { filename: 'src/a.md', additions: 0, deletions: 2, patch: '-x\n-x' },
    { filename: 'src/b.md', additions: 1, deletions: 0, patch: '+x' },
  ], config);
  assert.equal(summary.movedLines, 1);
});

test('a patchless modified file is rebuilt from both blobs', () => {
  // The case the backfill exists for: agents-private#170 emptied one 333KB
  // SKILL.md, GitHub omitted its patch, and without this the discount silently
  // did not apply to the change it was written for. Both refs must be read.
  const asked = [];
  const blobs = {
    base: ['keep', 'moved one', 'moved two'],
    head: ['keep', 'new summary'],
  };
  const readBlob = async (repo, path, ref) => {
    asked.push([path, ref]);
    return ref === 'BASE' ? blobs.base : blobs.head;
  };
  const files = [{ filename: 'skills/big/SKILL.md', status: 'modified', additions: 1, deletions: 2 }];
  return backfillMissingPatches(files, 'o/r', { base: { sha: 'BASE' }, head: { sha: 'HEAD' } }, readBlob)
    .then(() => {
      assert.deepEqual(asked, [['skills/big/SKILL.md', 'BASE'], ['skills/big/SKILL.md', 'HEAD']]);
      assert.equal(files[0].patchDerived, true);
      assert.deepEqual(files[0].patch.split('\n').sort(), ['+new summary', '-moved one', '-moved two']);
    });
});

test('a rename reads the base blob under its previous name', () => {
  const asked = [];
  const readBlob = async (repo, path, ref) => { asked.push([path, ref]); return ['a']; };
  const files = [{ filename: 'new/path.md', previous_filename: 'old/path.md', status: 'renamed' }];
  return backfillMissingPatches(files, 'o/r', { base: { sha: 'B' }, head: { sha: 'H' } }, readBlob)
    .then(() => assert.deepEqual(asked, [['old/path.md', 'B'], ['new/path.md', 'H']]));
});

test('an unreadable blob leaves the file without a patch', () => {
  // No patch means no proof means no discount. Silently deriving an empty diff
  // here would discount everything the checker could not read.
  const files = [{ filename: 'a.bin', status: 'modified' }];
  return backfillMissingPatches(files, 'o/r', { base: { sha: 'B' }, head: { sha: 'H' } }, async () => null)
    .then(() => assert.equal(files[0].patch, undefined));
});
