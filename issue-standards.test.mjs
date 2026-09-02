import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ConfigurationError,
  FORBIDDEN_HEADINGS,
  KINDS,
  REQUIRED_HEADINGS,
  kindFromLabels,
  lintTemplates,
  parseHighStakesGlobs,
  parseSections,
  suggestLabels,
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

test('lint is not fooled by a label that merely contains the heading', () => {
  // "Not the Job to be done" contains the words "Job to be done", but it is a
  // different field. Substring matching would call the required field present
  // when it is not.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h === 'Job to be done' ? 'Not the Job to be done' : h}`);
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const result = lintTemplates(dir);
    assert.ok(failed(result));
    assert.ok(failedOn(result, 'Job to be done'), JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('lint is not fooled by a label-shaped line inside a markdown block scalar', () => {
  // `value: |` starts a block scalar; everything indented under it is prose,
  // not YAML keys. A description that happens to say "label: Job to be done"
  // must not count as the field it describes.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h}`);
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const featureFile = path.join(dir, 'feature.yml');
    const withoutField = fs.readFileSync(featureFile, 'utf8').replace(/.*Job to be done.*\n/, '');
    fs.writeFileSync(featureFile, `${withoutField}  - type: markdown\n    attributes:\n      value: |\n        Copy this line if needed:\n        label: Job to be done\n`);
    const result = lintTemplates(dir);
    assert.ok(failed(result));
    assert.ok(failedOn(result, 'Job to be done'), JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('lint fails when a form offers a heading forbidden for its kind', () => {
  // Every issue this epic form produces would fail the body check: an epic
  // that carries its own acceptance criteria has not been decomposed.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h}`);
      if (kind === 'epic') fields.push('  - type: textarea\n    attributes:\n      label: Acceptance criteria');
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const result = lintTemplates(dir);
    assert.ok(failed(result));
    assert.ok(failedOn(result, 'Acceptance criteria'), JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('--selfcheck rejects extra arguments instead of silently ignoring them', () => {
  const result = run(['check', '--selfcheck', '--repo', 'not-a-repo']);
  assert.equal(result.status, 2);
});

const BUG = [
  '## Impact', 'Scheduled LinkedIn posts fail silently.',
  '## Reproduction', '1. Schedule a post.\nExpected: it publishes.\nActual: nothing.',
  '## Last known good', 'Worked on 2026-08-20.',
  '## Acceptance criteria', '- [ ] The post publishes.',
  '## How to verify', 'Schedule one and wait.',
].join('\n');

const EPIC = [
  '## Job to be done', 'The inbox cannot be shared across providers.',
  '## Slices', '- [ ] Extract the thread view.',
  '## Out of scope', 'Anything outside the inbox.',
].join('\n');

function swapped(body, from, to) {
  return body.replace(`## ${from}`, `## ${to}`);
}

test('alias group Job to be done: Why, Problem, Impact are accepted; canonical still works', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
  for (const alias of ['Why', 'Problem', 'Impact']) {
    const result = validateBody(swapped(FEATURE, 'Job to be done', alias), 'feature');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Today / Wanted: What, Current / Wanted are accepted; canonical still works', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
  for (const alias of ['What', 'Current / Wanted']) {
    const result = validateBody(swapped(FEATURE, 'Today / Wanted', alias), 'feature');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Acceptance criteria: Done, Definition of done are accepted; canonical still works', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
  for (const alias of ['Done', 'Definition of done']) {
    const result = validateBody(swapped(FEATURE, 'Acceptance criteria', alias), 'feature');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group How to verify: Verification, How verified, Testing are accepted; canonical still works', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
  for (const alias of ['Verification', 'How verified', 'Testing']) {
    const result = validateBody(swapped(FEATURE, 'How to verify', alias), 'feature');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Out of scope: Scope, Not included, Non-goals are accepted; canonical still works', () => {
  assert.equal(validateBody(EPIC, 'epic').failures.length, 0);
  for (const alias of ['Scope', 'Not included', 'Non-goals']) {
    const result = validateBody(swapped(EPIC, 'Out of scope', alias), 'epic');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Slices: Deliverables, Phases are accepted; canonical still works', () => {
  assert.equal(validateBody(EPIC, 'epic').failures.length, 0);
  for (const alias of ['Deliverables', 'Phases']) {
    const result = validateBody(swapped(EPIC, 'Slices', alias), 'epic');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Reproduction: Steps to reproduce, Repro are accepted; canonical still works', () => {
  assert.equal(validateBody(BUG, 'bug').failures.length, 0);
  for (const alias of ['Steps to reproduce', 'Repro']) {
    const result = validateBody(swapped(BUG, 'Reproduction', alias), 'bug');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Last known good: Regression, Last working are accepted; canonical still works', () => {
  assert.equal(validateBody(BUG, 'bug').failures.length, 0);
  for (const alias of ['Regression', 'Last working']) {
    const result = validateBody(swapped(BUG, 'Last known good', alias), 'bug');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('alias group Success metric: Metric, Success metrics are accepted; canonical still works', () => {
  assert.equal(validateBody(FEATURE, 'feature').failures.length, 0);
  for (const alias of ['Metric', 'Success metrics']) {
    const result = validateBody(swapped(FEATURE, 'Success metric', alias), 'feature');
    assert.equal(result.failures.length, 0, alias);
  }
});

test('R3: an epic carrying Done fails', () => {
  // Done is the fleet's name for acceptance criteria. An epic with either
  // heading has not been decomposed.
  const result = validateBody(`${EPIC}\n## Done\n- [ ] Everything works.`, 'epic');
  assert.ok(failed(result));
  assert.ok(failedOn(result, 'Acceptance criteria'), JSON.stringify(result.failures));
});

test('R3: an epic may carry an Exit gate', () => {
  // A gate is a condition for leaving a phase. Acceptance criteria are the
  // testable statements of one issue, and an epic is forbidden from carrying
  // those because its children do. Treating the two as one name made every
  // phase epic in the fleet fail a rule it does not break.
  const epic = [
    '## Job to be done', 'The migration cannot land in one step.',
    '## Slices', '- [ ] Phase one.',
    '## Out of scope', 'Anything outside the migration.',
    '## Exit gate', 'Runtime scans find no active resource.',
  ].join('\n');
  assert.equal(validateBody(epic, 'epic').failures.length, 0);
});

test('a stray empty alias heading does not hide a populated canonical one later in the body', () => {
  // An unrelated "## Why" intro, empty or otherwise, normalises to the same
  // target as "## Job to be done" now that the two are aliased. Picking
  // whichever match comes first in the document would report the required
  // heading as empty even though it was filled in further down.
  const body = [
    '## Why', '',
    FEATURE,
  ].join('\n');
  assert.equal(validateBody(body, 'feature').failures.length, 0);
});

test('lint accepts a required heading offered only through an alias label', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => {
        const label = h === 'Job to be done' ? 'Why' : h;
        return `  - type: textarea\n    attributes:\n      label: ${label}`;
      });
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const result = lintTemplates(dir);
    assert.equal(result.failures.length, 0, JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('lint rejects a forbidden heading offered only through an alias label', () => {
  // "Done" is the fleet's name for "Acceptance criteria". An epic form
  // offering it is exactly as forbidden as one offering the canonical name.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-templates-'));
  try {
    for (const kind of KINDS) {
      const fields = REQUIRED_HEADINGS[kind].map((h) => `  - type: textarea\n    attributes:\n      label: ${h}`);
      if (kind === 'epic' && FORBIDDEN_HEADINGS.epic.includes('Acceptance criteria')) {
        fields.push('  - type: textarea\n    attributes:\n      label: Done');
      }
      fs.writeFileSync(path.join(dir, `${kind}.yml`), `name: ${kind}\nbody:\n${fields.join('\n')}\n`);
    }
    const result = lintTemplates(dir);
    assert.ok(failed(result));
    assert.ok(failedOn(result, 'Acceptance criteria'), JSON.stringify(result.failures));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function pick(suggestions, group) {
  return suggestions.find((item) => item.group === group);
}

// Short enough to be mini once it has exactly one criterion, and chore-shaped
// so route tests can reuse it.
const MINI_CHORE_BODY = [
  'Rename the leftover helper.',
  '',
  '## Acceptance criteria',
  '- [ ] The helper has the new name.',
].join('\n');

test('suggest: defect language is a bug', () => {
  const out = suggestLabels('Login crash', 'The submit button is broken and fails.', [], []);
  assert.equal(pick(out, 'kind').label, 'bug');
});

test('suggest: chore language is a chore', () => {
  const out = suggestLabels('Refactor the save path', 'cleanup the module and bump the dependency', [], []);
  assert.equal(pick(out, 'kind').label, 'chore');
});

test('suggest: a Slices, Deliverables or Phases heading is an epic', () => {
  for (const heading of ['Slices', 'Deliverables', 'Phases']) {
    const out = suggestLabels('Inbox sharing', `## ${heading}\n- [ ] Extract the thread view.`, [], []);
    assert.equal(pick(out, 'kind').label, 'epic', heading);
  }
});

test('suggest: naming multiple phases is an epic', () => {
  const out = suggestLabels('Inbox sharing', 'Phase 1 extracts the view. Phase 2 shares it.', [], []);
  assert.equal(pick(out, 'kind').label, 'epic');
});

test('suggest: no kind signal is a feature', () => {
  const out = suggestLabels('Workspace badge', 'Show the workspace on each row.', [], []);
  assert.equal(pick(out, 'kind').label, 'feature');
});

test('suggest: a short body with one criterion is mini', () => {
  const out = suggestLabels('Rename helper', MINI_CHORE_BODY, [], []);
  assert.equal(pick(out, 'kind').label, 'chore');
  assert.equal(pick(out, 'size').label, 'mini');
});

test('suggest: a mid-size body is standard', () => {
  const body = `${'The list should show a workspace badge. '.repeat(20)}\n\n- [ ] Badge shows.\n- [ ] Filter still works.`;
  assert.ok(body.length >= 400 && body.length <= 2000, body.length);
  const out = suggestLabels('Workspace badge', body, [], []);
  assert.equal(pick(out, 'size').label, 'standard');
});

test('suggest: a body over 2000 chars is deep', () => {
  const body = `${'x'.repeat(2001)}\n\n- [ ] Done.`;
  assert.equal(pick(suggestLabels('Long write-up', body, [], []), 'size').label, 'deep');
});

test('suggest: more than five criteria is deep', () => {
  const body = ['Keep going.', '', '## Acceptance criteria', ...Array.from({ length: 6 }, (_, i) => `- [ ] Criterion ${i + 1}.`)].join('\n');
  assert.ok(body.length < 2000, body.length);
  assert.equal(pick(suggestLabels('Many checks', body, [], []), 'size').label, 'deep');
});

test('suggest: migration or multiple surfaces is deep', () => {
  assert.equal(pick(suggestLabels('Move data', 'This migration copies rows.\n\n- [ ] Copied.', [], []), 'size').label, 'deep');
  assert.equal(pick(suggestLabels('Badges', 'Touches multiple surfaces.\n\n- [ ] Done.', [], []), 'size').label, 'deep');
});

test('suggest: an epic is always deep', () => {
  const out = suggestLabels('Inbox sharing', '## Slices\n- [ ] One.', [], []);
  assert.equal(pick(out, 'kind').label, 'epic');
  assert.equal(pick(out, 'size').label, 'deep');
});

test('suggest: a high-stakes word forces route:judgement regardless of size', () => {
  // Mini chore would otherwise be mechanical. Auth is expensive even as a rename.
  const out = suggestLabels('Rename auth helper', MINI_CHORE_BODY, [], []);
  assert.equal(pick(out, 'kind').label, 'chore');
  assert.equal(pick(out, 'size').label, 'mini');
  assert.equal(pick(out, 'route').label, 'route:judgement');
});

test('suggest: a high-stakes glob in the body forces route:judgement', () => {
  const out = suggestLabels('Rename helper', `${MINI_CHORE_BODY}\n\nTouch src/payments/charge.ts`, [], ['src/payments/**']);
  assert.equal(pick(out, 'size').label, 'mini');
  assert.equal(pick(out, 'route').label, 'route:judgement');
});

test('suggest: mini chore with issues.md present is route:mechanical', () => {
  const out = suggestLabels('Rename helper', MINI_CHORE_BODY, [], []);
  assert.equal(pick(out, 'kind').label, 'chore');
  assert.equal(pick(out, 'size').label, 'mini');
  assert.equal(pick(out, 'route').label, 'route:mechanical');
});

test('suggest: without issues.md, never guess route:mechanical', () => {
  // Guessing low is the direction this must not be wrong in.
  const out = suggestLabels('Rename helper', MINI_CHORE_BODY, [], null);
  assert.equal(pick(out, 'kind').label, 'chore');
  assert.equal(pick(out, 'size').label, 'mini');
  assert.equal(pick(out, 'route').label, 'route:scoped');
  assert.match(pick(out, 'route').reason, /guessing low/);
});

test('suggest: an existing label is kept', () => {
  const out = suggestLabels('Login crash', 'The submit button is broken.', ['feature', 'mini'], []);
  assert.equal(pick(out, 'kind').label, 'feature');
  assert.equal(pick(out, 'kind').alreadySet, true);
  assert.match(pick(out, 'kind').reason, /already set/);
  assert.equal(pick(out, 'size').label, 'mini');
  assert.equal(pick(out, 'size').alreadySet, true);
  assert.equal(pick(out, 'state').label, 'triage');
});

test('suggest without --repo is a configuration error', () => {
  assert.equal(run(['suggest']).status, 2);
  assert.equal(run(['suggest', '--number', '1']).status, 2);
});

test('a plural high-stakes word still forces route:judgement', () => {
  // \b after a bare word cannot match a plural: \b needs a non-word character
  // and "s" is one. A real epic saying "owner-approved Cloudflare migrations"
  // was routed as ordinary work by exactly this, which is the direction the
  // route rule must never be wrong in.
  const body = 'Remove unused resources through separate owner-approved Cloudflare migrations.';
  const route = suggestLabels('Purge infrastructure', body, [], []).find((s) => s.group === 'route');
  assert.equal(route.label, 'route:judgement', JSON.stringify(route));

  // The singular must keep working, and a bare prefix must not over-match:
  // "author" is not "auth".
  const routeOf = (body) => suggestLabels('x', body, [], []).find((s) => s.group === 'route').label;
  assert.equal(routeOf('a billing migration'), 'route:judgement');
  assert.notEqual(routeOf('the author wrote docs'), 'route:judgement');
});

test('a consonant-y chore word still matches its -ies plural', () => {
  // The same \b-after-bare-word gap as the migrations bug, for a word that
  // pluralizes irregularly: "dependency" + an s/es suffix never spells
  // "dependencies", so "Update dependencies" fell through to feature. The
  // body is otherwise signal-free so only the title word is on trial.
  const out = suggestLabels('Update dependencies', 'Keep the app current.', [], []);
  assert.equal(out.find((s) => s.group === 'kind').label, 'chore');
});

test('a high-stakes glob matches a mentioned path at repo root, not only nested', () => {
  // "**" folded its adjoining "/" into a literal in the compiled regex, so
  // "**/payments/**" required a "/" before "payments" and never matched the
  // root-level path "payments/charge.ts".
  const out = suggestLabels('Rename helper', `${MINI_CHORE_BODY}\n\nTouch payments/charge.ts`, [], ['**/payments/**']);
  assert.equal(out.find((s) => s.group === 'route').label, 'route:judgement');
});

test('repeating the same phase number is not multiple phases', () => {
  const out = suggestLabels('Inbox sharing', 'See phase 1 above. As noted in phase 1, this is simple.', [], []);
  assert.notEqual(out.find((s) => s.group === 'kind').label, 'epic');
});

test('parseHighStakesGlobs accepts a root-level path with no slash or wildcard', () => {
  const markdown = ['| Path | Why |', '| --- | --- |', '| `wrangler.toml` | infra config |'].join('\n');
  assert.deepEqual(parseHighStakesGlobs(markdown), ['wrangler.toml']);
});

test('an already-set epic kind still forces size deep on a short body', () => {
  // guessSize used the freshly-guessed kind rather than the kind the issue
  // already carries, so an issue already labelled epic but whose body has
  // no epic signal of its own (no Slices heading, no repeated phase) was
  // sized "mini" instead of the "epics are always deep" rule.
  const body = 'Fix nothing.\n\n- [ ] One thing.';
  const out = suggestLabels('Some title', body, ['epic'], []);
  assert.equal(out.find((s) => s.group === 'kind').label, 'epic');
  assert.equal(out.find((s) => s.group === 'kind').alreadySet, true);
  assert.equal(out.find((s) => s.group === 'size').label, 'deep');
  assert.equal(out.find((s) => s.group === 'size').reason, 'epics are always deep');
});

test('a high-stakes glob still matches a path followed by sentence punctuation', () => {
  // The path-extraction regex includes "." in its character class, so a
  // path at the end of a sentence ("Touch infra/wrangler.toml.") captured
  // the closing period as part of the filename and then never matched the
  // glob it was written to hit.
  const out = suggestLabels(
    'Rename helper',
    `${MINI_CHORE_BODY}\n\nTouch infra/wrangler.toml.`,
    [],
    ['infra/*.toml'],
  );
  assert.equal(out.find((s) => s.group === 'route').label, 'route:judgement');
});
