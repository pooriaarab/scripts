import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ConfigurationError,
  REQUIRED_HEADINGS,
  parseSections,
  validateBody,
} from './issue-standards.mjs';

const LAUNCHER = fileURLToPath(new URL('./issue-standards', import.meta.url));

// A body that satisfies every rule, so each test can break exactly one thing.
const FEATURE = [
  '## Job to be done',
  'I manage three brands and cannot tell which workspace a post belongs to.',
  '',
  '## Today / Wanted',
  'Today: the list shows no workspace.',
  'Wanted: each row carries a workspace badge.',
  '',
  '## Acceptance criteria',
  '- [ ] Each row shows the workspace name.',
  '',
  '## How to verify',
  'Open the posts list as a multi-workspace user. Every row shows a badge.',
  '',
  '## Success metric',
  'Event: publish_success',
  'Question: does cross-posting to the wrong workspace fall?',
  'Threshold: no regression over 14 days',
].join('\n');

const failed = (result) => result.failures.length > 0;
const failedOn = (result, fragment) => result.failures.some((f) => f.check.includes(fragment)
  || f.expected.includes(fragment) || f.fix.includes(fragment));

function run(args, options = {}) {
  return spawnSync(process.execPath, [LAUNCHER, ...args], { encoding: 'utf8', ...options });
}

function withBody(body, run_) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-standards-'));
  try {
    const file = path.join(dir, 'body.md');
    fs.writeFileSync(file, body);
    return run_(file, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('a complete feature body passes', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
});

test('R1: a missing required heading fails, and names the heading', () => {
  const result = validateBody(FEATURE.replace('## How to verify', '## Notes'), 'feature');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'How to verify'), JSON.stringify(result.failures));
});

test('R6: a heading present but empty fails', () => {
  // Worse than a missing heading, because it looks answered.
  const body = FEATURE.replace('I manage three brands and cannot tell which workspace a post belongs to.', '');
  const result = validateBody(body, 'feature');
  assert.ok(failed(result));
  assert.ok(result.failures.some((f) => f.got === 'empty'), JSON.stringify(result.failures));
});

test('R6: a body still carrying the form placeholder fails', () => {
  // The forms ship `Today:` / `Wanted:` as scaffolding. Submitting them
  // unchanged is the most common way an issue looks filled in and is not.
  const body = FEATURE.replace(
    'Today: the list shows no workspace.\nWanted: each row carries a workspace badge.',
    'Today:\nWanted:',
  );
  assert.ok(failed(validateBody(body, 'feature')));
});

test('R2: acceptance criteria without a checkbox fails', () => {
  const body = FEATURE.replace('- [ ] Each row shows the workspace name.', 'Each row shows the workspace name.');
  const result = validateBody(body, 'feature');
  assert.ok(failed(result));
  assert.ok(failedOn(result, '- [ ]'), JSON.stringify(result.failures));
});

test('R2: a ticked checkbox still counts as a criterion', () => {
  const body = FEATURE.replace('- [ ] Each row', '- [x] Each row');
  assert.equal(validateBody(body, 'feature').failures.length, 0);
});

test('R4: a Parent line in the body fails, and points at the native link', () => {
  const result = validateBody(`Parent: #1119\n\n${FEATURE}`, 'feature');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'sub-issue'), JSON.stringify(result.failures));
});

test('R4: a Blocked by line fails the same way', () => {
  assert.ok(failed(validateBody(`Blocked by: #42\n\n${FEATURE}`, 'feature')));
});

test('R4: prose merely mentioning a parent is not a false positive', () => {
  // The rule targets the convention, which is a line-leading label, not any
  // sentence containing the word. Rejecting honest prose is the direction this
  // check must not be wrong in.
  const body = FEATURE.replace('## How to verify', '## How to verify\nThe parent epic #1119 tracks the rest.\n');
  assert.equal(validateBody(body, 'feature').failures.length, 0);
});

test('R5: a success metric with no event name fails', () => {
  const body = FEATURE.replace('Event: publish_success', 'Event: to be decided later');
  const result = validateBody(body, 'feature');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'snake_case'), JSON.stringify(result.failures));
});

test('R5: only a feature is asked for a success metric', () => {
  const chore = [
    '## Job to be done', 'Four files must be read to find where drafts save.',
    '## Today / Wanted', 'Today: scattered. Wanted: one module.',
    '## Acceptance criteria', '- [ ] Behaviour unchanged.',
    '## How to verify', 'bun run test passes.',
  ].join('\n');
  assert.equal(validateBody(chore, 'chore').failures.length, 0);
});

test('R3: an epic carrying acceptance criteria fails', () => {
  // Its children carry them. An epic that needs its own was never decomposed.
  const epic = [
    '## Job to be done', 'The inbox cannot be shared across providers.',
    '## Slices', '- [ ] Extract the thread view.',
    '## Out of scope', 'Anything outside the inbox.',
    '## Acceptance criteria', '- [ ] Everything works.',
  ].join('\n');
  const result = validateBody(epic, 'epic');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'decomposed'), JSON.stringify(result.failures));
});

test('a bug is checked against its own headings, not the feature spine', () => {
  const bug = [
    '## Impact', 'Scheduled LinkedIn posts fail silently.',
    '## Reproduction', '1. Schedule a post.\nExpected: it publishes.\nActual: nothing.',
    '## Last known good', 'Worked on 2026-08-20.',
    '## Acceptance criteria', '- [ ] The post publishes.',
    '## How to verify', 'Schedule one and wait.',
  ].join('\n');
  assert.equal(validateBody(bug, 'bug').failures.length, 0);
  // A bug carries no success metric, so the feature rule must not apply to it.
  assert.ok(!REQUIRED_HEADINGS.bug.includes('Success metric'));
});

test('headings are matched loosely, because a human types what the form suggests', () => {
  assert.equal(validateBody(FEATURE.replace('## Today / Wanted', '## Today/Wanted'), 'feature').failures.length, 0);
  assert.equal(validateBody(FEATURE.replace('## Job to be done', '### Job To Be Done'), 'feature').failures.length, 0);
});

test('a heading inside a fenced block is not a heading', () => {
  const body = `${FEATURE}\n\n\`\`\`markdown\n## Acceptance criteria\n\`\`\`\n`;
  const sections = parseSections(body);
  assert.equal(sections.filter((s) => s.heading === 'Acceptance criteria').length, 1);
});

test('precheck runs offline against a body file', () => {
  withBody(FEATURE, (file) => {
    const result = run(['precheck', '--body-file', file, '--kind', 'feature']);
    assert.equal(result.status, 0, result.stdout + result.stderr);
  });
  withBody(FEATURE.replace('## How to verify', '## Notes'), (file) => {
    const result = run(['precheck', '--body-file', file, '--kind', 'feature']);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stdout, /How to verify/);
  });
});

test('--json is machine readable on every command', () => {
  withBody(FEATURE, (file) => {
    const result = run(['precheck', '--body-file', file, '--kind', 'feature', '--json']);
    const parsed = JSON.parse(result.stdout);
    assert.equal(parsed.clean, true);
    assert.equal(parsed.mode, 'precheck');
  });
});

test('exit codes match pr-standards: 0 clean, 1 failures, 2 configuration', () => {
  withBody(FEATURE.replace('## How to verify', '## Notes'), (file) => {
    assert.equal(run(['precheck', '--body-file', file, '--kind', 'feature']).status, 1);
  });
  assert.equal(run(['precheck', '--body-file', '/nope/missing.md', '--kind', 'feature']).status, 2);
  assert.equal(run(['precheck', '--kind', 'feature']).status, 2);
  assert.equal(run(['precheck', '--body-file', '/tmp', '--kind', 'nonsense']).status, 2);
  assert.equal(run(['nonsense']).status, 2);
});

test('an unknown kind is a configuration error, not a silent pass', () => {
  assert.throws(() => validateBody(FEATURE, 'improvement'), ConfigurationError);
});

