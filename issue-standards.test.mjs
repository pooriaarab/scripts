import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ConfigurationError,
  KINDS,
  REQUIRED_HEADINGS,
  kindFromLabels,
  lintTemplates,
  parseSections,
  validateBody,
  validateLabels,
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

test('R3: labels need exactly one from each of four groups', () => {
  assert.equal(validateLabels(['feature', 'mini', 'route:mechanical', 'triage']).failures.length, 0);

  const missing = validateLabels(['feature', 'mini', 'triage']);
  assert.ok(failed(missing));
  assert.ok(missing.failures.some((f) => f.check.startsWith('route')), JSON.stringify(missing.failures));

  const doubled = validateLabels(['feature', 'bug', 'mini', 'route:mechanical', 'triage']);
  assert.ok(failed(doubled));
  assert.ok(doubled.failures.some((f) => f.got.includes('bug') && f.got.includes('feature')));
});

test('an unrecognised label is ignored rather than treated as a group member', () => {
  assert.equal(validateLabels(['feature', 'mini', 'route:mechanical', 'triage', 'good first issue']).failures.length, 0);
});

test('the kind comes from the label, and is unknown when ambiguous', () => {
  assert.equal(kindFromLabels(['feature', 'mini']), 'feature');
  assert.equal(kindFromLabels(['feature', 'bug']), null);
  assert.equal(kindFromLabels(['mini']), null);
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
  assert.equal(run(['--selfcheck']).status, 0);
  withBody(FEATURE.replace('## How to verify', '## Notes'), (file) => {
    assert.equal(run(['precheck', '--body-file', file, '--kind', 'feature']).status, 1);
  });
  assert.equal(run(['precheck', '--body-file', '/nope/missing.md', '--kind', 'feature']).status, 2);
  assert.equal(run(['precheck', '--kind', 'feature']).status, 2);
  assert.equal(run(['precheck', '--body-file', '/tmp', '--kind', 'nonsense']).status, 2);
  assert.equal(run(['nonsense']).status, 2);
  assert.equal(run(['check', '--repo', 'not-a-repo']).status, 2);
});

test('an unknown kind is a configuration error, not a silent pass', () => {
  assert.throws(() => validateBody(FEATURE, 'improvement'), ConfigurationError);
});

test('lint fails when a form stops offering a required heading', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h}`);
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    assert.equal(lintTemplates(dir).failures.length, 0);

    // Drop one field. The form and the checker have drifted, and an issue filed
    // through the form would fail the check the form exists to satisfy.
    const featureFile = path.join(dir, 'feature.yml');
    fs.writeFileSync(featureFile, fs.readFileSync(featureFile, 'utf8').replace(/.*Success metric.*\n/, ''));
    const drifted = lintTemplates(dir);
    assert.ok(failed(drifted));
    assert.ok(failedOn(drifted, 'Success metric'), JSON.stringify(drifted.failures));

    fs.rmSync(path.join(dir, 'epic.yml'));
    assert.ok(lintTemplates(dir).failures.some((f) => f.check === 'epic.yml'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('lint says so when the repo has no templates at all', () => {
  const result = lintTemplates('/nope/no-such-directory');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'ISSUE_TEMPLATE'), JSON.stringify(result.failures));
});

test('lint is not fooled by the heading text surviving outside the field label', () => {
  // The field for "Success metric" is gone, but the phrase lingers in an
  // unrelated description. A text-wide search would call this fine; it is not.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h}`);
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const featureFile = path.join(dir, 'feature.yml');
    const withoutField = fs.readFileSync(featureFile, 'utf8').replace(/.*Success metric.*\n/, '');
    fs.writeFileSync(featureFile, `${withoutField}  - type: markdown\n    attributes:\n      value: See the Success metric section of the standard.\n`);
    const result = lintTemplates(dir);
    assert.ok(failed(result));
    assert.ok(failedOn(result, 'Success metric'), JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('--selfcheck rejects extra arguments instead of silently ignoring them', () => {
  const result = run(['check', '--selfcheck', '--repo', 'not-a-repo']);
  assert.equal(result.status, 2);
});
