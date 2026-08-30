import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ConfigurationError,
  DEFAULT_CONFIG,
  checkProof,
  checkSize,
  countClosingReferences,
  validateCommits,
  validateConfig,
  derivePrefix,
  hasUiDiff,
  isCommittedProofMedia,
  isUiFile,
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

test('override label short-circuits size failures', () => {
  const summary = {
    rawLines: 900,
    countedLines: 700,
    excludedLines: 200,
    rawFiles: 45,
    countedFiles: 45,
    excludedFiles: 0,
    topLevelDirs: ['a', 'b', 'c', 'd'],
  };
  const result = checkSize(summary, { ...config, maxLines: 500, maxFiles: 40 }, ['oversized-approved']);

  assert.equal(result.overridden, true);
  assert.equal(result.failures.length, 0);
  assert.equal(result.warnings.length, 1);
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

test('proof: a visible change needs before and after attachments', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const withUrls = (n) => `${validBody}\n` + Array.from({ length: n }, (_, i) =>
    `![shot](https://github.com/user-attachments/assets/abc${i})`).join('\n');
  const proofNa = `${validBody}\nProof: n/a — a type-level refactor with no runtime path`;
  const proofNaShort = `${validBody}\nProof: n/a — no ui`;

  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  assert.equal(failed(checkProof(validBody, uiFiles, [], config)), true);
  assert.equal(warned(checkProof(withUrls(1), uiFiles, [], config)), true);
  assert.equal(failed(checkProof(withUrls(1), uiFiles, [], config)), false);
  assert.equal(failed(checkProof(withUrls(2), uiFiles, [], config)), false);
  assert.equal(warned(checkProof(withUrls(2), uiFiles, [], config)), false);

  // A stated reason clears it; "n/a" on its own does not, or the escape hatch
  // becomes the default and the rule stops meaning anything.
  assert.equal(failed(checkProof(proofNa, uiFiles, [], config)), false);
  assert.equal(failed(checkProof(proofNaShort, uiFiles, [], config)), true);

  // Nothing visible changed, so nothing has to be shown.
  assert.equal(failed(checkProof(validBody, [{ filename: 'src/server/api.ts', status: 'modified' }], [], config)), false);
  assert.equal(failed(checkProof(validBody, [{ filename: 'src/components/Button.test.tsx', status: 'modified' }], [], config)), false);

  assert.equal(isUiFile('src/components/Button.tsx', config), true);
  assert.equal(isUiFile('src/components/Button.test.tsx', config), false);
  assert.equal(hasUiDiff(uiFiles, config), true);
  assert.equal(hasUiDiff([{ filename: 'src/server/api.ts' }], config), false);

  // A Next.js Pages Router API route lives under pages/ but renders nothing —
  // the broad **/pages/** glob must not send it down the screenshot path.
  assert.equal(isUiFile('pages/api/users.ts', config), false);
  assert.equal(isUiFile('src/pages/api/[id].ts', config), false);
  assert.equal(isUiFile('pages/index.tsx', config), true);
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
    const r = checkProof(validBody, [file], [], config);
    assert.equal(r.failures.some((f) => f.check === 'committed proof media'), true, `checkProof should flag ${file.filename}`);
  }

  // Everything else is a product asset. A repo full of real images must not
  // start failing because one of them is a png.
  for (const filename of ['public/logo.png', 'public/assets/bg.jpg', 'src/assets/icon.png', 'assets/image.png', 'src/app/logo.png']) {
    const file = { filename, status: 'added' };
    assert.equal(isCommittedProofMedia(file), false, `should not flag ${filename}`);
    const r = checkProof(validBody, [file], [], config);
    assert.equal(r.failures.length + r.warnings.length, 0);
  }

  // Only an added file is suspicious: editing a media file already in the repo
  // is maintenance of a real asset.
  assert.equal(isCommittedProofMedia({ filename: 'screenshots/home.png', status: 'modified' }), false);
  assert.equal(isCommittedProofMedia({ filename: 'screenshots/readme.txt', status: 'added' }), false);
});

test('proof: the owner label and requireProof clear the checks', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const media = [{ filename: 'screenshots/home.png', status: 'added' }];

  const waived = checkProof(validBody, [...uiFiles, ...media], ['proof-not-applicable'], config);
  assert.equal(waived.failures.length, 0);
  assert.equal(waived.overridden, true);

  const off = { ...config, requireProof: false };
  assert.equal(checkProof(validBody, [...uiFiles, ...media], [], off).failures.length, 0);
});

test('proof: the loopholes the council found in the first pass stay closed', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `![shot](https://github.com/user-attachments/assets/${id})`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  // The same image pasted twice is one image, not before and after.
  const duplicated = `${validBody}\n${url('abc')}\n${url('abc')}`;
  assert.equal(warned(checkProof(duplicated, uiFiles, [], config)), true);
  assert.equal(warned(checkProof(`${validBody}\n${url('abc')}\n${url('def')}`, uiFiles, [], config)), false);

  // A body documenting the escape hatch quotes it. A quoted rule must not
  // satisfy the rule it quotes.
  const quoted = `${validBody}\n\n\`\`\`\nProof: n/a — the documented escape hatch\n\`\`\``;
  assert.equal(failed(checkProof(quoted, uiFiles, [], config)), true);
  assert.equal(failed(checkProof(`${validBody}\nProof: n/a — the documented escape hatch`, uiFiles, [], config)), false);

  // Renaming a component out of components/ is still a visible change.
  const renamedOut = [{ filename: 'src/lib/Button.ts', previous_filename: 'src/components/Button.tsx', status: 'renamed' }];
  assert.equal(hasUiDiff(renamedOut, config), true);
  assert.equal(hasUiDiff([{ filename: 'src/lib/util.ts', status: 'modified' }], config), false);

  // An opening fence with no closing one runs to the end of the document on
  // GitHub too — the "Proof: n/a" line inside it must not count as plain text.
  const unclosed = `${validBody}\n\n\`\`\`\nProof: n/a — the documented escape hatch, unclosed`;
  assert.equal(failed(checkProof(unclosed, uiFiles, [], config)), true);

  // A bare URL followed by sentence punctuation is still the same asset as
  // the same id embedded as a markdown image.
  const sentence = `${validBody}\n${url('abc')}\nSee https://github.com/user-attachments/assets/abc.`;
  assert.equal(warned(checkProof(sentence, uiFiles, [], config)), true);
  assert.equal(failed(checkProof(sentence, uiFiles, [], config)), false);

  // Evidence has to live in "How I verified" — an attachment or a "Proof: n/a"
  // line stashed under a different heading is not proof of anything.
  const bodyWithHeading = (extra) => `Closes #142\n\n## What\nFixes it.\n\n## Why\nBecause.\n\n## Notes\n${extra}\n\n## How I verified\nbun test -> 214 passed`;
  assert.equal(failed(checkProof(bodyWithHeading(url('abc')), uiFiles, [], config)), true);
  assert.equal(failed(checkProof(bodyWithHeading('Proof: n/a — a reason placed under the wrong heading'), uiFiles, [], config)), true);

  // A fence closes on a line with at least as many of the same character as
  // opened it, not on a literal three. A four-backtick fence used to hide a
  // real, four-backtick-only closing line and run to the end of the document,
  // swallowing genuine proof that came after it.
  const fourBacktickThenReal = `${validBody}\n\n\`\`\`\`\nhidden\n\`\`\`\`\n\n${url('abc')}\n${url('def')}`;
  assert.equal(warned(checkProof(fourBacktickThenReal, uiFiles, [], config)), false);
  assert.equal(failed(checkProof(fourBacktickThenReal, uiFiles, [], config)), false);

  // A ``` fence still only closes on ```, never on a same-position ~~~ line —
  // mixing fence characters must not close early and un-hide the middle of a
  // fenced block.
  const mismatchedFence = `${validBody}\n\n\`\`\`\n~~~\nProof: n/a — still inside the backtick fence, not closed by tildes\n\`\`\``;
  assert.equal(failed(checkProof(mismatchedFence, uiFiles, [], config)), true);
});

test('proof: an indented code line is not a fence, and an angle-bracketed URL is the same asset', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `https://github.com/user-attachments/assets/${id}`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  // Four spaces of indent is indented code, not a fence opener. Treating it as
  // one swallowed every line after it, so real proof below vanished and a PR
  // that had done nothing wrong failed.
  const indented = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '    ```  an indented line that merely contains backticks',
    `![before](${url('aaa')})`,
    `![after](${url('bbb')})`,
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(indented, uiFiles, [], config)), false);
  assert.equal(warned(checkProof(indented, uiFiles, [], config)), false);

  // A real fence still hides what it wraps.
  const fenced = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '```', `![quoted](${url('aaa')})`, '```',
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(fenced, uiFiles, [], config)), true);

  // <url> and url are the same asset, so pasting one image both ways is still
  // one image and must not clear the before-and-after threshold.
  const angled = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass', url('aaa'), `<${url('aaa')}>`,
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(warned(checkProof(angled, uiFiles, [], config)), true);
});

test('proof: a second council pass loopholes stay closed', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `https://github.com/user-attachments/assets/${id}`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  // The same asset once as a Markdown image and once wrapped in inline code is
  // still one image, not before and after — a trailing backtick is not part
  // of the URL.
  const backtickWrapped = `${validBody}\n![shot](${url('abc')})\nAlso see \`${url('abc')}\`.`;
  assert.equal(warned(checkProof(backtickWrapped, uiFiles, [], config)), true);
  assert.equal(failed(checkProof(backtickWrapped, uiFiles, [], config)), false);

  // A fenced example quoted inside a blockquote is still a fence: two
  // attachment URLs quoted there as documentation must not count as real
  // before-and-after proof.
  const blockquotedFence = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '> ```', `> ![before](${url('aaa')})`, `> ![after](${url('bbb')})`, '> ```',
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(blockquotedFence, uiFiles, [], config)), true);
  assert.equal(warned(checkProof(blockquotedFence, uiFiles, [], config)), false);

  // An HTML comment that spans across a fence's own closing line must not
  // delete that closer and swallow real proof written after it.
  const commentEatsCloser = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '```', 'hidden', '<!-- note', '```', 'still hidden', '-->',
    `![before](${url('aaa')})`, `![after](${url('bbb')})`,
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(commentEatsCloser, uiFiles, [], config)), false);
  assert.equal(warned(checkProof(commentEatsCloser, uiFiles, [], config)), false);
});

test('proof: a third council pass loopholes stay closed', () => {
  const uiFiles = [{ filename: 'src/components/Button.tsx', status: 'modified' }];
  const url = (id) => `https://github.com/user-attachments/assets/${id}`;
  const failed = (r) => r.failures.some((f) => f.check === 'proof of a visible change');
  const warned = (r) => r.warnings.some((w) => w.check === 'proof of a visible change');

  // Four spaces of indent renders as an indented code block on GitHub — the
  // same syntax this convention's own docs use to show the escape hatch. A
  // body that quotes that example must not be read as invoking it.
  const indentedProofNa = `${validBody}\n\n    Proof: n/a — quoting the documented escape hatch verbatim`;
  assert.equal(failed(checkProof(indentedProofNa, uiFiles, [], config)), true);

  // A fence marker sitting inside an HTML comment is raw comment text, not a
  // real opener — it must not swallow real proof written after the comment
  // closes.
  const fenceInsideComment = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '<!-- example:', '```', '-->',
    `![before](${url('aaa')})`, `![after](${url('bbb')})`,
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(fenceInsideComment, uiFiles, [], config)), false);
  assert.equal(warned(checkProof(fenceInsideComment, uiFiles, [], config)), false);

  // A real fence containing something that looks like a comment marker must
  // still hide its contents — the comment-open check must never run inside
  // an already-open fence.
  const commentInsideFence = [
    '## What', 'x', '## Why', 'y', '## How I verified',
    'ran it -> pass',
    '```', `<!-- ![quoted](${url('aaa')}) -->`, '```',
    'Assisted-by: agent:model',
  ].join('\n');
  assert.equal(failed(checkProof(commentInsideFence, uiFiles, [], config)), true);
});
