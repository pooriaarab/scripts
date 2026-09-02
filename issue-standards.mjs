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
  issue-standards precheck --body-file F --kind <${KINDS.join('|')}>

Add --json for machine-readable output.`;
}

function parseArgs(argv) {
  const args = [...argv];
  const json = args.includes('--json');
  const filtered = args.filter((arg) => arg !== '--json');
  if (filtered.includes('--help') || filtered.includes('-h')) return { help: true };
  const mode = filtered.shift();
  if (mode !== 'precheck') {
    throw new ConfigurationError('usage: issue-standards precheck --body-file F --kind <bug|feature|chore|epic>');
  }
  const options = { mode, json, positional: [] };
  for (let index = 0; index < filtered.length; index += 1) {
    const arg = filtered[index];
    if (['--body-file', '--kind'].includes(arg)) {
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

function runPrecheck(options) {
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

export async function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) {
      process.stdout.write(`${usage()}\n`);
      return 0;
    }
    return runPrecheck(options);
  } catch (error) {
    const item = fail(
      'configuration',
      error.message,
      'a valid command',
      'Fix the command.',
    );
    const json = options?.json || argv.includes('--json');
    if (json) outputJson({ clean: false, failures: [item], passes: [] });
    else process.stderr.write(`FAIL  ${item.check}\n${humanFailure(item)}\n`);
    return error.name === 'ConfigurationError' ? 2 : 1;
  }
}
