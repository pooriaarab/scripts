import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

// The standard this enforces is issue-standards.md, beside this file. It checks
// shape and nothing else. Whether the job to be done is real, whether the
// acceptance criteria cover it, and whether the size and route are honest are
// judgements a program cannot make, and a checker that claimed to make them
// would be believed and be wrong.

export const KINDS = ['bug', 'feature', 'chore', 'epic'];

// The spine is the same for every kind except bug, which trades Job to be done
// for Impact, and epic, which has no criteria of its own.
export const REQUIRED_HEADINGS = {
  bug: ['Impact', 'Reproduction', 'Last known good', 'Acceptance criteria', 'How to verify'],
  feature: ['Job to be done', 'Today / Wanted', 'Acceptance criteria', 'How to verify', 'Success metric'],
  chore: ['Job to be done', 'Today / Wanted', 'Acceptance criteria', 'How to verify'],
  epic: ['Job to be done', 'Slices', 'Out of scope'],
};

// An epic that carries its own acceptance criteria has not been decomposed. Its
// children carry them, so the heading appearing here is the signal, not a bonus.
export const FORBIDDEN_HEADINGS = { epic: ['Acceptance criteria'] };

export const LABEL_GROUPS = {
  kind: KINDS,
  size: ['mini', 'standard', 'deep'],
  route: ['route:mechanical', 'route:scoped', 'route:judgement'],
  state: ['triage', 'ready-for-agent', 'needs-info', 'blocked'],
};

const CHECKBOX_RE = /^\s*[-*]\s+\[[ xX]\]/m;
// A parent written in prose is a parent no tool knows about.
const NATIVE_LINK_RE = /^\s*(Parent|Blocked by)\s*:\s*#?\d+/im;
// Event names are lowercase snake_case with at least one underscore, which is
// what distinguishes a real one from a sentence.
const EVENT_RE = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/;

export class ConfigurationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigurationError';
  }
}

export class ApiError extends Error {
  constructor(message, status = null) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

function fail(check, got, expected, fix) {
  return { check, got, expected, fix };
}

// Headings are compared loosely because a human types what a form suggests, not
// what a regex wants. "Today / Wanted" and "Today/Wanted" are the same heading.
function normaliseHeading(text) {
  return String(text).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

// Split a markdown body into { heading, body } sections. Fenced code is skipped
// so a `## ` inside an example block does not read as a real heading.
export function parseSections(body) {
  const sections = [];
  let current = null;
  let fenced = false;
  for (const line of String(body || '').split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    const heading = fenced ? null : /^#{1,6}\s+(.+?)\s*$/.exec(line);
    if (heading) {
      current = { heading: heading[1].trim(), lines: [] };
      sections.push(current);
    } else if (current) {
      current.lines.push(line);
    }
  }
  return sections.map((section) => ({
    heading: section.heading,
    body: section.lines.join('\n').trim(),
  }));
}

function findSection(sections, wanted) {
  const target = normaliseHeading(wanted);
  return sections.find((section) => normaliseHeading(section.heading) === target) || null;
}

// A body still carrying the form's own prompt text has not been filled in. The
// forms ship `Today:` / `Wanted:` and bare checkboxes as scaffolding, and an
// issue that submits them unchanged looks answered and is not.
function isPlaceholderOnly(text) {
  const meaningful = String(text)
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !/^(today|wanted|event|question|threshold|expected|actual|environment)\s*:?\s*$/i.test(line))
    .filter((line) => !/^[-*]\s*\[[ xX]\]\s*$/.test(line))
    .filter((line) => !/^\d+\.\s*$/.test(line));
  return meaningful.length === 0;
}

// The one rule that does not depend on the kind. Kept separate so it still runs
// on an issue carrying no kind label, which is exactly the unlabelled backlog
// this standard exists to clean up.
export function validateNativeLinks(body) {
  const failures = [];
  const match = NATIVE_LINK_RE.exec(String(body || ''));
  if (match) {
    failures.push(fail(
      'parent or blocker in the body',
      match[0].trim(),
      'a native sub-issue or issue dependency',
      'Use the sub-issues API for a parent and issue dependencies for a blocker. Body text is invisible to every query, filter and board.',
    ));
  }
  return { failures, passes: [] };
}

export function validateBody(body, kind) {
  if (!KINDS.includes(kind)) {
    throw new ConfigurationError(`kind must be one of ${KINDS.join(', ')}, got: ${kind}`);
  }
  const failures = [];
  const passes = [];
  const sections = parseSections(body);

  for (const heading of REQUIRED_HEADINGS[kind]) {
    const section = findSection(sections, heading);
    if (!section) {
      failures.push(fail(
        `## ${heading}`,
        'missing',
        `a "## ${heading}" section`,
        `Add "## ${heading}" and fill it in.`,
      ));
      continue;
    }
    if (!section.body || isPlaceholderOnly(section.body)) {
      failures.push(fail(
        `## ${heading}`,
        'empty',
        'a section with content',
        'Write it or delete the heading. An empty heading looks answered.',
      ));
      continue;
    }
    passes.push(`## ${heading}`);
  }

  for (const heading of FORBIDDEN_HEADINGS[kind] || []) {
    if (findSection(sections, heading)) {
      failures.push(fail(
        `## ${heading} on an ${kind}`,
        `an ${kind} carrying "## ${heading}"`,
        `no "## ${heading}" on an ${kind}`,
        'Its children carry the criteria. An epic that needs its own has not been decomposed.',
      ));
    }
  }

  // Only meaningful where the kind has criteria at all.
  if (REQUIRED_HEADINGS[kind].includes('Acceptance criteria')) {
    const section = findSection(sections, 'Acceptance criteria');
    if (section && section.body && !CHECKBOX_RE.test(section.body)) {
      failures.push(fail(
        'acceptance criteria',
        'no checkbox items',
        'at least one "- [ ]" item',
        'Write each criterion as a checkbox. Each one testable, each one true or false.',
      ));
    }
  }

  failures.push(...validateNativeLinks(body).failures);

  if (kind === 'feature') {
    const section = findSection(sections, 'Success metric');
    if (section && section.body && !EVENT_RE.test(section.body)) {
      failures.push(fail(
        'success metric event',
        'no event name',
        'a snake_case event name, or a statement that the event has to be added',
        'Name a real event. Never invent one: the next agent will search for it and conclude the code is broken.',
      ));
    }
  }

  return { failures, passes };
}

export function validateLabels(labels) {
  const present = new Set((labels || []).map((label) => String(label).toLowerCase()));
  const failures = [];
  const passes = [];
  for (const [group, allowed] of Object.entries(LABEL_GROUPS)) {
    const found = allowed.filter((label) => present.has(label));
    if (found.length === 0) {
      failures.push(fail(
        `${group} label`,
        'none',
        `exactly one of: ${allowed.join(', ')}`,
        `Add one ${group} label.`,
      ));
    } else if (found.length > 1) {
      failures.push(fail(
        `${group} label`,
        found.join(', '),
        `exactly one of: ${allowed.join(', ')}`,
        'Two from one group is a contradiction, not extra information. Remove all but one.',
      ));
    } else {
      passes.push(`${group} label: ${found[0]}`);
    }
  }
  return { failures, passes };
}

// The kind is whichever kind label the issue carries. Without one there is
// nothing to check the headings against, so say that rather than guessing.
export function kindFromLabels(labels) {
  const present = new Set((labels || []).map((label) => String(label).toLowerCase()));
  const found = KINDS.filter((kind) => present.has(kind));
  return found.length === 1 ? found[0] : null;
}

function ghJson(args) {
  try {
    const out = execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return JSON.parse(out);
  } catch (error) {
    const stderr = String(error.stderr || error.message || '');
    if (/not found|404/i.test(stderr)) throw new ApiError(`not found: ${args.join(' ')}`, 404);
    throw new ApiError(`gh failed: ${stderr.trim().split('\n')[0] || 'unknown error'}`);
  }
}

export function fetchIssue(repo, number) {
  const issue = ghJson(['api', `repos/${repo}/issues/${number}`]);
  return {
    number: issue.number,
    title: issue.title || '',
    body: issue.body || '',
    labels: (issue.labels || []).map((label) => (typeof label === 'string' ? label : label.name)),
  };
}

function humanFailure(item, prefix = '      ') {
  return `${prefix}got:      ${item.got}\n${prefix}expected: ${item.expected}\n${prefix}fix:      ${item.fix}`;
}

function outputHuman(result) {
  const lines = [];
  if (result.subject) lines.push(result.subject);
  for (const pass of result.passes || []) lines.push(`PASS  ${pass}`);
  for (const item of result.failures || []) lines.push(`FAIL  ${item.check}\n${humanFailure(item)}`);
  lines.push(result.clean ? 'OK' : `${result.failures.length} failure(s)`);
  process.stdout.write(`${lines.join('\n')}\n`);
}

function outputJson(result) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function finish(result, json) {
  result.clean = result.failures.length === 0;
  if (json) outputJson(result);
  else outputHuman(result);
  return result.clean ? 0 : 1;
}

function usage() {
  return `Usage:
  issue-standards check --repo owner/name --number N
  issue-standards precheck --body-file F --kind <${KINDS.join('|')}>
  issue-standards lint [--dir D]
  issue-standards --selfcheck

Add --json to any command for machine-readable output.`;
}

function parseArgs(argv) {
  const args = [...argv];
  const json = args.includes('--json');
  const filtered = args.filter((arg) => arg !== '--json');
  if (filtered.includes('--help') || filtered.includes('-h')) return { help: true };
  if (filtered.includes('--selfcheck')) return { selfcheck: true, json };
  const mode = filtered.shift();
  if (!mode || !['check', 'precheck', 'lint'].includes(mode)) {
    throw new ConfigurationError('usage: issue-standards check --repo owner/name --number N, precheck --body-file F --kind K, or lint');
  }
  const options = { mode, json, positional: [] };
  for (let index = 0; index < filtered.length; index += 1) {
    const arg = filtered[index];
    if (['--repo', '--number', '--body-file', '--kind', '--dir'].includes(arg)) {
      const value = filtered[index + 1];
      if (!value || value.startsWith('--')) throw new ConfigurationError(`${arg} requires a value`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
      index += 1;
    } else if (arg.startsWith('--')) {
      throw new ConfigurationError(`unknown option: ${arg}`);
    } else {
      options.positional.push(arg);
    }
  }
  return options;
}

function runCheck(options) {
  if (options.bodyFile || options.kind || options.dir) {
    throw new ConfigurationError('check accepts --repo and --number only');
  }
  if (!options.repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repo)) {
    throw new ConfigurationError('check requires --repo owner/name');
  }
  if (!options.number || !/^[1-9][0-9]*$/.test(options.number)) {
    throw new ConfigurationError('check requires --number N');
  }
  const issue = fetchIssue(options.repo, options.number);
  const labelResult = validateLabels(issue.labels);
  const kind = kindFromLabels(issue.labels);
  const failures = [...labelResult.failures];
  const passes = [...labelResult.passes];
  if (kind) {
    const bodyResult = validateBody(issue.body, kind);
    failures.push(...bodyResult.failures);
    passes.push(...bodyResult.passes);
  } else {
    // Without a kind there is nothing to check the headings against, but the
    // rules that do not depend on one still apply.
    failures.push(...validateNativeLinks(issue.body).failures);
  }
  return finish({
    mode: 'check',
    subject: `${options.repo}#${issue.number}  kind: ${kind || 'unknown'}`,
    kind,
    failures,
    passes,
  }, options.json);
}

function runPrecheck(options) {
  if (options.repo || options.number || options.dir) {
    throw new ConfigurationError('precheck accepts --body-file and --kind only');
  }
  if (!options.bodyFile) throw new ConfigurationError('precheck requires --body-file');
  if (!options.kind) throw new ConfigurationError(`precheck requires --kind <${KINDS.join('|')}>`);
  // statSync, not existsSync: a directory exists, and reading one throws EISDIR
  // deep inside, which surfaced as an ordinary failure rather than as the
  // configuration error it is.
  if (!fs.existsSync(options.bodyFile) || !fs.statSync(options.bodyFile).isFile()) {
    throw new ConfigurationError(`not a readable file: ${options.bodyFile}`);
  }
  const body = fs.readFileSync(options.bodyFile, 'utf8');
  const result = validateBody(body, options.kind);
  return finish({
    mode: 'precheck',
    subject: `${options.bodyFile}  kind: ${options.kind}`,
    kind: options.kind,
    failures: result.failures,
    passes: result.passes,
  }, options.json);
}

// The forms are what people actually fill in, so they have to keep offering
// every heading the checker demands. Without this the two drift and an issue
// filed through the form fails the check that the form exists to satisfy.
export function lintTemplates(dir) {
  const failures = [];
  const passes = [];
  if (!fs.existsSync(dir)) {
    return { failures: [fail('templates', `no such directory: ${dir}`, 'a .github/ISSUE_TEMPLATE directory', 'Adopt the standard in this repo, or pass --dir.')], passes };
  }
  for (const kind of KINDS) {
    const file = `${dir}/${kind}.yml`;
    if (!fs.existsSync(file)) {
      failures.push(fail(`${kind}.yml`, 'missing', `a form at ${file}`, `Add the ${kind} form.`));
      continue;
    }
    const text = fs.readFileSync(file, 'utf8');
    const missing = REQUIRED_HEADINGS[kind].filter((heading) => {
      const loose = normaliseHeading(heading).replace(/ /g, '[^a-z0-9]*');
      return !new RegExp(loose, 'i').test(normaliseHeading(text).replace(/ /g, ' '))
        && !new RegExp(loose, 'i').test(text.toLowerCase());
    });
    if (missing.length) {
      failures.push(fail(
        `${kind}.yml`,
        `no field for: ${missing.join(', ')}`,
        `a field per required heading: ${REQUIRED_HEADINGS[kind].join(', ')}`,
        'The form and the checker have drifted. An issue filed through the form would fail the check.',
      ));
    } else {
      passes.push(`${kind}.yml`);
    }
  }
  return { failures, passes };
}

function runLint(options) {
  if (options.repo || options.number || options.bodyFile || options.kind) {
    throw new ConfigurationError('lint accepts --dir only');
  }
  const dir = options.dir || '.github/ISSUE_TEMPLATE';
  const result = lintTemplates(dir);
  return finish({ mode: 'lint', subject: dir, failures: result.failures, passes: result.passes }, options.json);
}

// A checker nobody has checked is a checker nobody should trust. This asserts
// each rule fires on a body built to break it, so a rule silently deleted shows
// up here rather than in a pull request that should have been refused.
function runSelfcheck(json) {
  const failures = [];
  const passes = [];
  const expect = (label, condition) => {
    if (condition) passes.push(label);
    else failures.push(fail(label, 'rule did not fire', 'the rule to fire', 'A rule has been weakened or deleted.'));
  };

  const good = [
    '## Job to be done', 'Cannot tell which workspace a post belongs to.',
    '## Today / Wanted', 'Today: nothing. Wanted: a badge.',
    '## Acceptance criteria', '- [ ] The badge renders.',
    '## How to verify', 'Open the list. The badge is there.',
    '## Success metric', 'Event: publish_success', 'Threshold: no change',
  ].join('\n');

  expect('a complete feature passes', validateBody(good, 'feature').failures.length === 0);
  expect('a missing heading fails', validateBody(good.replace('## How to verify', '## Something else'), 'feature').failures.length > 0);
  expect('an empty required heading fails', validateBody(good.replace('Cannot tell which workspace a post belongs to.', ''), 'feature').failures.length > 0);
  expect('an unfilled form placeholder fails', validateBody(good.replace('Today: nothing. Wanted: a badge.', 'Today:\nWanted:'), 'feature').failures.length > 0);
  expect('criteria without a checkbox fails', validateBody(good.replace('- [ ] The badge renders.', 'It renders.'), 'feature').failures.length > 0);
  expect('a Parent line fails', validateBody(`Parent: #12\n${good}`, 'feature').failures.length > 0);
  expect('a success metric with no event fails', validateBody(good.replace('Event: publish_success', 'Event: to be decided'), 'feature').failures.length > 0);
  expect('an epic with criteria fails', validateBody('## Job to be done\nx\n## Slices\n- [ ] a\n## Out of scope\nx\n## Acceptance criteria\n- [ ] b', 'epic').failures.length > 0);
  expect('a full label set passes', validateLabels(['feature', 'mini', 'route:mechanical', 'triage']).failures.length === 0);
  expect('two from one group fails', validateLabels(['feature', 'bug', 'mini', 'route:mechanical', 'triage']).failures.length > 0);
  expect('a missing group fails', validateLabels(['feature', 'mini', 'triage']).failures.length > 0);

  return finish({ mode: 'selfcheck', subject: 'issue-standards selfcheck', failures, passes }, json);
}

export async function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) {
      process.stdout.write(`${usage()}\n`);
      return 0;
    }
    if (options.selfcheck) return runSelfcheck(options.json);
    if (options.mode === 'check') return runCheck(options);
    if (options.mode === 'precheck') return runPrecheck(options);
    return runLint(options);
  } catch (error) {
    const item = fail(
      error.name === 'ConfigurationError' ? 'configuration' : 'GitHub API',
      error.message,
      'a valid command and an accessible repository',
      'Fix the command, or check gh authentication.',
    );
    const json = options?.json || argv.includes('--json');
    if (json) outputJson({ clean: false, failures: [item], passes: [] });
    else process.stderr.write(`FAIL  ${item.check}\n${humanFailure(item)}\n`);
    return error.name === 'ConfigurationError' ? 2 : 1;
  }
}
