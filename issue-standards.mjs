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

// The fleet already had names for these sections before the standard froze
// its own. Accept either so existing issues pass. Failures still name the
// canonical heading so new issues converge. Impact stays canonical for a bug
// and is only an alias of Job to be done for the other kinds.
export const HEADING_ALIASES = {
  'Job to be done': ['Why', 'Problem', 'Impact'],
  'Today / Wanted': ['What', 'Current / Wanted'],
  // 'Exit gate' is deliberately NOT here. A gate is a condition for leaving a
  // phase; acceptance criteria are the testable statements of one issue. An
  // epic is forbidden from carrying criteria, so aliasing the two made every
  // phase epic fail a rule it does not break.
  'Acceptance criteria': ['Done', 'Definition of done'],
  'How to verify': ['Verification', 'How verified', 'Testing'],
  'Out of scope': ['Scope', 'Not included', 'Non-goals'],
  'Slices': ['Deliverables', 'Phases'],
  'Reproduction': ['Steps to reproduce', 'Repro'],
  'Last known good': ['Regression', 'Last working'],
  'Success metric': ['Metric', 'Success metrics'],
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
// A relationship written in prose is a relationship no tool knows about.
// Line-leading labels only, then an issue reference or a phase name. A
// sentence that merely contains "depends" is not a relationship.
const NATIVE_LINK_RE = /^\s*(Parent|Blocked by|Depends on|Blocks|Related to)\s*:?\s*(?:#?\d+|Phase\s+\S+)/im;
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

// Canonical plus every accepted alternative, all through the same normalisation
// so "Exit gate" and "exit-gate" are the same heading.
function namesFor(canonical) {
  return [canonical, ...(HEADING_ALIASES[canonical] || [])].map(normaliseHeading);
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

// More than one heading can normalise into the same target once aliases are in
// play (an old "## Why" alongside the canonical "## Job to be done"). The first
// match is not necessarily the one that was filled in, so prefer whichever
// match actually has content and only fall back to the first when none do.
function findSection(sections, wanted) {
  const targets = new Set(namesFor(wanted));
  const matches = sections.filter((section) => targets.has(normaliseHeading(section.heading)));
  if (matches.length === 0) return null;
  return matches.find((section) => section.body && !isPlaceholderOnly(section.body)) || matches[0];
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
      'a native sub-issue or issue dependency, not body text',
      'Use the sub-issues API for a parent and issue dependencies for a blocker or a dependency. A dependency is a native issue dependency, not body text. Body text is invisible to every query, filter and board.',
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

// Assignee is never checked. An agent does not assign work.

// The allowed sets live in .agents/issues.md beside the high-stakes paths.
// A field with no set is not checked: zero milestones exist across the fleet,
// and a rule that always required one would fail every issue.
export function parseAllowedSets(markdown) {
  if (markdown == null) return { projects: null, milestones: null };
  return {
    projects: parseNamedList(markdown, 'Allowed projects'),
    milestones: parseNamedList(markdown, 'Allowed milestones'),
  };
}

function parseNamedList(markdown, heading) {
  const target = normaliseHeading(heading);
  const lines = String(markdown).split('\n');
  let inSection = false;
  let seen = false;
  const items = [];

  const takeItem = (raw) => {
    const text = String(raw).replace(/^\*\*|\*\*$/g, '').trim();
    if (!text || /^[-:]+$/.test(text)) return;
    if (/^(project|projects|milestone|milestones|name|title|notes|why)$/i.test(text)) return;
    const tick = /`([^`]+)`/.exec(text);
    items.push(tick ? tick[1].trim() : text.replace(/[,.]$/, '').trim());
  };

  for (const line of lines) {
    const headingMatch = /^#{1,6}\s+(.+?)\s*$/.exec(line);
    if (headingMatch) {
      if (inSection) break;
      inSection = normaliseHeading(headingMatch[1]) === target;
      seen = seen || inSection;
      continue;
    }
    const labelled = /^(?:\*\*)?(Allowed (?:projects|milestones))(?:\*\*)?\s*:?\s*(.*)$/i.exec(line.trim());
    if (labelled) {
      if (normaliseHeading(labelled[1]) === target) {
        seen = true;
        inSection = true;
        if (labelled[2]) {
          for (const part of labelled[2].split(',')) takeItem(part);
        }
      } else if (inSection) {
        break;
      }
      continue;
    }
    if (!inSection) continue;
    if (/^\s*\|/.test(line)) {
      if (/^\s*\|\s*:?-/.test(line)) continue;
      const cells = line.split('|').map((cell) => cell.trim()).filter(Boolean);
      if (cells[0]) takeItem(cells[0]);
      continue;
    }
    const bullet = /^\s*(?:[-*]|\d+\.)\s+(.+)$/.exec(line);
    if (bullet) takeItem(bullet[1]);
  }
  return seen ? items : null;
}

function namesMatch(left, right) {
  return String(left).trim().toLowerCase() === String(right).trim().toLowerCase();
}

export function validateFields(issue, allowed) {
  const failures = [];
  const passes = [];
  const projects = Array.isArray(issue?.projects)
    ? issue.projects.filter(Boolean)
    : (issue?.project ? [issue.project] : []);
  const milestone = issue?.milestone || null;
  const sets = allowed || {};

  if (Array.isArray(sets.projects)) {
    const unexpected = projects.filter((name) => !sets.projects.some((allowedName) => namesMatch(name, allowedName)));
    if (unexpected.length) {
      failures.push(fail(
        'project',
        unexpected.join(', '),
        `one of: ${sets.projects.join(', ')}`,
        `Move the issue to an allowed project. Allowed projects: ${sets.projects.join(', ')}.`,
      ));
    } else if (projects.length) {
      passes.push(`project: ${projects.join(', ')}`);
    }
  }

  if (Array.isArray(sets.milestones)) {
    if (milestone && !sets.milestones.some((allowedName) => namesMatch(milestone, allowedName))) {
      failures.push(fail(
        'milestone',
        milestone,
        `one of: ${sets.milestones.join(', ')}`,
        `Set a milestone from the allowed set. Allowed milestones: ${sets.milestones.join(', ')}.`,
      ));
    } else if (milestone) {
      passes.push(`milestone: ${milestone}`);
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

const BUG_WORDS = ['defect', 'error', 'crash', 'regression', 'fails', 'broken'];
const CHORE_WORDS = ['refactor', 'dependency', 'bump', 'ci', 'docs', 'cleanup', 'rename'];
const HIGH_STAKES_WORDS = ['auth', 'billing', 'credits', 'migration', 'webhook', 'rbac', 'token', 'middleware'];

function hasWord(text, word) {
  // Allow a plural suffix. A trailing \b after the bare word cannot match
  // "migrations", because \b needs a non-word character and "s" is one, so
  // every plural form silently missed. A real issue saying "owner-approved
  // Cloudflare migrations" was routed as ordinary work by exactly this.
  // The suffix is opt-in rather than a bare prefix match: \bauth with no
  // boundary would also match "author" and "authored".
  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // A consonant-y word (dependency) pluralizes as -ies, not -ys: "Update
  // dependencies" must still match "dependency", the CHORE_WORDS entry.
  const plural = /[^aeiou]y$/i.test(word)
    ? `${escaped.slice(0, -1)}(?:y|ies)`
    : `${escaped}(?:s|es)?`;
  return new RegExp(`\\b${plural}\\b`, 'i').test(text);
}

function firstWord(text, words) {
  return words.find((word) => hasWord(text, word)) || null;
}

function countCriteria(body) {
  return (String(body || '').match(/^\s*[-*]\s+\[[ xX]\]/gm) || []).length;
}

function namesMultiplePhases(text) {
  // Count distinct phases, not mentions: a body that says "Phase 1" twice
  // (once in prose, once in a recap) names one phase, not two, and is not
  // an epic on that signal alone.
  const matches = String(text).match(/\bphase\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b/gi) || [];
  const distinct = new Set(matches.map((match) => match.toLowerCase().replace(/\s+/g, ' ')));
  return distinct.size >= 2;
}

function hasEpicHeading(body) {
  const targets = new Set(namesFor('Slices'));
  return parseSections(body).some((section) => targets.has(normaliseHeading(section.heading)));
}

function guessKind(title, body) {
  const text = `${title}\n${body}`;
  if (firstWord(text, BUG_WORDS)) return { label: 'bug', reason: 'defect language' };
  if (firstWord(text, CHORE_WORDS)) return { label: 'chore', reason: 'chore language' };
  if (hasEpicHeading(body)) return { label: 'epic', reason: 'slices heading' };
  if (namesMultiplePhases(text)) return { label: 'epic', reason: 'names multiple phases' };
  return { label: 'feature', reason: 'no defect, chore or epic signal' };
}

function guessSize(body, kind) {
  if (kind === 'epic') return { label: 'deep', reason: 'epics are always deep' };
  const length = String(body || '').length;
  const criteria = countCriteria(body);
  if (length > 2000) return { label: 'deep', reason: 'body over 2000 chars' };
  if (criteria > 5) return { label: 'deep', reason: 'more than 5 criteria' };
  if (hasWord(body, 'migration')) return { label: 'deep', reason: 'mentions migration' };
  if (/multiple surfaces/i.test(body)) return { label: 'deep', reason: 'mentions multiple surfaces' };
  if (length < 400 && criteria === 1) return { label: 'mini', reason: 'body under 400 chars with one criterion' };
  return { label: 'standard', reason: 'neither mini nor deep' };
}

function globMatch(glob, filePath) {
  // A bare "**" -> ".*" leaves the glob's own adjoining "/" in the output,
  // so "**/payments/**" becomes "^.*/payments/.*$", which requires a slash
  // right before "payments" and so never matches the root-level path
  // "payments/charge.ts". "**/" and "/**" fold that slash into the
  // optional group instead, so a globstar can also match zero directories.
  const source = String(glob)
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*\*\//g, '::GSS::')
    .replace(/\/\*\*/g, '::SGS::')
    .replace(/\*\*/g, '::GS::')
    .replace(/\*/g, '[^/]*')
    .replace(/::GSS::/g, '(?:.*/)?')
    .replace(/::SGS::/g, '(?:/.*)?')
    .replace(/::GS::/g, '.*');
  return new RegExp(`^${source}$`).test(filePath);
}

function mentionedPaths(text) {
  const nested = String(text).match(/(?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+/g) || [];
  // A root-level file such as `wrangler.toml` has no "/" for the pattern
  // above to require, so a high-stakes glob written with a wildcard (e.g.
  // `*.toml`, rather than the literal filename parseHighStakesGlobs already
  // handles via a plain substring check) would never see it as a candidate.
  const bareFiles = String(text).match(/\b[A-Za-z0-9_-]+\.[A-Za-z0-9]+\b/g) || [];
  // The character class includes ".", so a path at the end of a sentence
  // ("Touch infra/wrangler.toml.") captures the closing period as part of
  // the filename and then never matches the glob it was written to hit.
  return [...nested, ...bareFiles].map((path) => path.replace(/[.,;:!?)\]]+$/, ''));
}

function guessRoute(title, body, kind, size, highStakesGlobs) {
  const text = `${title}\n${body}`;
  const word = firstWord(text, HIGH_STAKES_WORDS);
  if (word) return { label: 'route:judgement', reason: `mentions ${word}` };
  if (Array.isArray(highStakesGlobs)) {
    const paths = mentionedPaths(text);
    const glob = highStakesGlobs.find((item) => text.includes(item) || paths.some((filePath) => globMatch(item, filePath)));
    if (glob) return { label: 'route:judgement', reason: `touches ${glob}` };
  }
  // No issues.md: never guess mechanical. Guessing low is the direction this
  // must not be wrong in.
  if (highStakesGlobs == null) {
    return { label: 'route:scoped', reason: 'no .agents/issues.md; guessing low is the direction this must not be wrong in' };
  }
  if (size === 'mini' && kind === 'chore') {
    return { label: 'route:mechanical', reason: 'mini chore and no high-stakes path' };
  }
  return { label: 'route:scoped', reason: 'not mini-chore' };
}

// Pure so tests can exercise the rules without GitHub. highStakesGlobs is null
// when .agents/issues.md is absent, and an array (maybe empty) when it is not.
export function suggestLabels(title, body, existingLabels, highStakesGlobs) {
  const present = new Set((existingLabels || []).map((label) => String(label).toLowerCase()));
  // Size and route must reason from the kind and size an issue already
  // carries, not the freshly-guessed one: an issue already labelled epic
  // but with a short body would otherwise get sized "mini", contradicting
  // "epics are always deep" the moment the guess and the existing label
  // disagree.
  const existingKind = LABEL_GROUPS.kind.find((label) => present.has(label));
  const existingSize = LABEL_GROUPS.size.find((label) => present.has(label));
  const kind = guessKind(title, body);
  const effectiveKind = existingKind || kind.label;
  const size = guessSize(body, effectiveKind);
  const effectiveSize = existingSize || size.label;
  const route = guessRoute(title, body, effectiveKind, effectiveSize, highStakesGlobs);
  const state = { label: 'triage', reason: 'nothing here has been agreed' };
  const guesses = { kind, size, route, state };
  const suggestions = [];
  for (const [group, allowed] of Object.entries(LABEL_GROUPS)) {
    const existing = allowed.filter((label) => present.has(label));
    if (existing.length > 0) {
      suggestions.push({ group, label: existing[0], reason: 'already set', alreadySet: true });
    } else {
      suggestions.push({ group, label: guesses[group].label, reason: guesses[group].reason, alreadySet: false });
    }
  }
  return suggestions;
}

export function parseHighStakesGlobs(markdown) {
  const globs = [];
  for (const line of String(markdown || '').split('\n')) {
    if (!/^\s*\|/.test(line) || /^\s*\|\s*-+/.test(line)) continue;
    const cells = line.split('|').map((cell) => cell.trim()).filter(Boolean);
    // A root-level file such as `wrangler.toml` is a valid high-stakes path
    // even with no "/" or "*": requiring one silently dropped it, which is
    // the direction this table must never be wrong in.
    const tick = cells[0] && /`([^`]+)`/.exec(cells[0]);
    if (tick) globs.push(tick[1]);
  }
  return globs;
}

function ghJson(args, execOptions = {}) {
  try {
    const out = execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...execOptions });
    return JSON.parse(out);
  } catch (error) {
    const stderr = String(error.stderr || error.message || '');
    if (/not found|404/i.test(stderr)) throw new ApiError(`not found: ${args.join(' ')}`, 404);
    throw new ApiError(`gh failed: ${stderr.trim().split('\n')[0] || 'unknown error'}`);
  }
}

export function fetchIssue(repo, number) {
  const issue = ghJson(['api', `repos/${repo}/issues/${number}`]);
  // GitHub's issues endpoint returns pull requests too: a PR is an issue with
  // a `pull_request` key. This standard is for filed issues, not PRs.
  if (issue.pull_request) {
    throw new ApiError(`#${number} is a pull request, not an issue`, 422);
  }
  return {
    number: issue.number,
    title: issue.title || '',
    body: issue.body || '',
    labels: (issue.labels || []).map((label) => (typeof label === 'string' ? label : label.name)),
    // REST carries the milestone. Projects v2 need a second call.
    milestone: issue.milestone && issue.milestone.title ? issue.milestone.title : null,
    projects: fetchIssueProjects(repo, number),
  };
}

// Same reader the suggest command uses for high-stakes paths. One fetch of
// .agents/issues.md, then each parser takes what it needs.
export function fetchRepoFile(repo, filePath) {
  try {
    const file = ghJson(['api', `repos/${repo}/contents/${filePath}`]);
    if (!file || file.type !== 'file' || !file.content) return null;
    return Buffer.from(String(file.content).replace(/\n/g, ''), 'base64').toString('utf8');
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}

function fetchIssueProjects(repo, number) {
  try {
    // title is the project name. Token may lack read:project; then this is
    // empty rather than a check failure.
    const extra = ghJson(['issue', 'view', String(number), '--repo', repo, '--json', 'projectItems']);
    return (extra.projectItems || []).map((item) => item.title).filter(Boolean);
  } catch (error) {
    if (error instanceof ApiError) return [];
    throw error;
  }
}

function humanFailure(item, prefix = '      ') {
  return `${prefix}got:      ${item.got}\n${prefix}expected: ${item.expected}\n${prefix}fix:      ${item.fix}`;
}

function outputHuman(result) {
  if (result.mode === 'suggest') {
    const lines = [...(result.lines || [])];
    for (const item of result.failures || []) lines.push(`FAIL  ${item.check}\n${humanFailure(item)}`);
    if ((result.failures || []).length) lines.push(`${result.failures.length} failure(s)`);
    process.stdout.write(`${lines.join('\n')}\n`);
    return;
  }
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
  issue-standards suggest --repo owner/name [--number N] [--apply]
  issue-standards --selfcheck

Add --json to any command for machine-readable output.`;
}

function parseArgs(argv) {
  const args = [...argv];
  const json = args.includes('--json');
  const filtered = args.filter((arg) => arg !== '--json');
  if (filtered.includes('--help') || filtered.includes('-h')) return { help: true };
  if (filtered.includes('--selfcheck')) {
    if (filtered.length > 1) throw new ConfigurationError('--selfcheck takes no other arguments');
    return { selfcheck: true, json };
  }
  const mode = filtered.shift();
  if (!mode || !['check', 'precheck', 'lint', 'suggest'].includes(mode)) {
    throw new ConfigurationError('usage: issue-standards check --repo owner/name --number N, precheck --body-file F --kind K, lint, or suggest --repo owner/name');
  }
  const options = { mode, json, apply: false, positional: [] };
  for (let index = 0; index < filtered.length; index += 1) {
    const arg = filtered[index];
    if (['--repo', '--number', '--body-file', '--kind', '--dir'].includes(arg)) {
      const value = filtered[index + 1];
      if (!value || value.startsWith('--')) throw new ConfigurationError(`${arg} requires a value`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
      index += 1;
    } else if (arg === '--apply') {
      options.apply = true;
    } else if (arg.startsWith('--')) {
      throw new ConfigurationError(`unknown option: ${arg}`);
    } else {
      options.positional.push(arg);
    }
  }
  return options;
}

function runCheck(options) {
  if (options.bodyFile || options.kind || options.dir || options.apply) {
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
  // Reuse the suggest-command reader. Do not open .agents/issues.md a second way.
  const allowed = parseAllowedSets(fetchRepoFile(options.repo, '.agents/issues.md'));
  const fieldResult = validateFields(issue, allowed);
  const kind = kindFromLabels(issue.labels);
  const failures = [...labelResult.failures, ...fieldResult.failures];
  const passes = [...labelResult.passes, ...fieldResult.passes];
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
  if (options.repo || options.number || options.dir || options.apply) {
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

// A YAML block scalar (`value: |`) can carry lines that look like `label: X`
// as plain description text, not a field. Without stripping those out first,
// a form that merely mentions a heading in prose would count as still
// offering the field, hiding real drift.
function stripBlockScalars(text) {
  const kept = [];
  let blockIndent = null;
  for (const line of text.split('\n')) {
    if (blockIndent !== null) {
      if (line.trim() === '') continue;
      const indent = /^ */.exec(line)[0].length;
      if (indent > blockIndent) continue;
      blockIndent = null;
    }
    const scalarStart = /^(\s*)\S+:\s*[|>][+-]?\d*\s*$/.exec(line);
    if (scalarStart) blockIndent = scalarStart[1].length;
    kept.push(line);
  }
  return kept.join('\n');
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
    const text = stripBlockScalars(fs.readFileSync(file, 'utf8'));
    // Only a field's own `label:` counts. Matching anywhere in the file would
    // let the heading's words survive in an unrelated description after the
    // field itself was renamed or removed, and lint would miss the drift.
    // Equality, not substring: a label of "Not the Job to be done" is not the
    // "Job to be done" field, even though the words appear inside it.
    const fieldLabels = [...text.matchAll(/^\s*label:\s*(.+)$/gim)].map((m) => normaliseHeading(m[1]));
    // Aliases go through the same label equality as the canonical name. A
    // mention in a description is still not a field.
    const offers = (heading) => namesFor(heading).some((name) => fieldLabels.includes(name));
    const missing = REQUIRED_HEADINGS[kind].filter((heading) => !offers(heading));
    // A forbidden heading offered by the form is just as much drift as a
    // missing required one: every issue it produces will fail the body check.
    // Aliases of the forbidden heading are the same field under another name.
    const forbidden = (FORBIDDEN_HEADINGS[kind] || []).filter((heading) => offers(heading));
    if (missing.length) {
      failures.push(fail(
        `${kind}.yml`,
        `no field for: ${missing.join(', ')}`,
        `a field per required heading: ${REQUIRED_HEADINGS[kind].join(', ')}`,
        'The form and the checker have drifted. An issue filed through the form would fail the check.',
      ));
    }
    if (forbidden.length) {
      failures.push(fail(
        `${kind}.yml`,
        `field for: ${forbidden.join(', ')}`,
        `no field for ${forbidden.join(', ')} on the ${kind} form`,
        `Every issue this form produces will fail the check. Remove the field from ${kind}.yml.`,
      ));
    }
    if (!missing.length && !forbidden.length) passes.push(`${kind}.yml`);
  }
  return { failures, passes };
}

function runLint(options) {
  if (options.repo || options.number || options.bodyFile || options.kind || options.apply) {
    throw new ConfigurationError('lint accepts --dir only');
  }
  const dir = options.dir || '.github/ISSUE_TEMPLATE';
  const result = lintTemplates(dir);
  return finish({ mode: 'lint', subject: dir, failures: result.failures, passes: result.passes }, options.json);
}

function fetchOpenIssues(repo) {
  // Up to 1000 issues with full bodies can exceed execFileSync's default 1MB
  // stdout buffer and crash with ENOBUFS; pr-standards.mjs raises the same
  // limit for its own large `gh api` reads.
  const issues = ghJson([
    'issue', 'list', '--repo', repo, '--state', 'open', '--limit', '1000',
    '--json', 'number,title,body,labels',
  ], { maxBuffer: 20 * 1024 * 1024 });
  return (issues || []).map((issue) => ({
    number: issue.number,
    title: issue.title || '',
    body: issue.body || '',
    labels: (issue.labels || []).map((label) => (typeof label === 'string' ? label : label.name)),
  }));
}

function applyLabel(repo, number, label) {
  try {
    execFileSync('gh', ['issue', 'edit', String(number), '--repo', repo, '--add-label', label], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    const stderr = String(error.stderr || error.message || '');
    throw new ApiError(`gh failed: ${stderr.trim().split('\n')[0] || 'unknown error'}`);
  }
}

function runSuggest(options) {
  if (options.bodyFile || options.kind || options.dir) {
    throw new ConfigurationError('suggest accepts --repo, --number and --apply only');
  }
  if (!options.repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repo)) {
    throw new ConfigurationError('suggest requires --repo owner/name');
  }
  if (options.number && !/^[1-9][0-9]*$/.test(options.number)) {
    throw new ConfigurationError('suggest --number requires N');
  }
  const markdown = fetchRepoFile(options.repo, '.agents/issues.md');
  const globs = markdown == null ? null : parseHighStakesGlobs(markdown);
  const issues = options.number
    ? [fetchIssue(options.repo, options.number)]
    : fetchOpenIssues(options.repo);

  const failures = [];
  const passes = [];
  const lines = [];
  const suggestions = [];
  for (const issue of issues) {
    const items = suggestLabels(issue.title, issue.body, issue.labels, globs);
    suggestions.push({ number: issue.number, items });
    for (const item of items) {
      const reason = item.alreadySet ? 'already set' : item.reason;
      const line = `#${issue.number}  ${item.label}  ${reason}`;
      lines.push(line);
      if (options.apply && !item.alreadySet) {
        try {
          applyLabel(options.repo, issue.number, item.label);
          passes.push(line);
        } catch (error) {
          failures.push(fail(
            `#${issue.number} ${item.label}`,
            error.message,
            'gh issue edit to add the label',
            'Check gh authentication and that the label exists on the repo.',
          ));
        }
      } else {
        passes.push(line);
      }
    }
  }
  return finish({
    mode: 'suggest',
    subject: options.number ? `${options.repo}#${options.number}` : `${options.repo} open issues`,
    apply: Boolean(options.apply),
    suggestions,
    lines,
    failures,
    passes,
  }, options.json);
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
  expect('a Depends on issue line fails', validateBody(`Depends on #12\n${good}`, 'feature').failures.length > 0);
  expect('a Depends on Phase line fails', validateBody(`Depends on Phase 10.\n${good}`, 'feature').failures.length > 0);
  expect('prose containing depends does not fail', validateBody(good.replace('Open the list. The badge is there.', 'The result depends on the cache. Open the list. The badge is there.'), 'feature').failures.length === 0);
  expect('a project outside the allowed set fails', validateFields({ projects: ['Secret'] }, { projects: ['Roadmap'], milestones: null }).failures.length > 0);
  expect('a field with no set defined passes', validateFields({ projects: ['Anything'], milestone: 'v9' }, { projects: null, milestones: null }).failures.length === 0);
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
    if (options.mode === 'suggest') return runSuggest(options);
    return runLint(options);
  } catch (error) {
    const item = fail(
      error instanceof ConfigurationError ? 'configuration' : error instanceof ApiError ? 'GitHub API' : 'unexpected error',
      error.message,
      'a valid command and an accessible repository',
      error instanceof ApiError ? 'Fix the command, or check gh authentication.' : 'Fix the command.',
    );
    const json = options?.json || argv.includes('--json');
    if (json) outputJson({ clean: false, failures: [item], passes: [] });
    else process.stderr.write(`FAIL  ${item.check}\n${humanFailure(item)}\n`);
    return error instanceof ConfigurationError ? 2 : 1;
  }
}
