import fs from 'node:fs';
import path from 'node:path';
import { execFile, execFileSync, spawnSync } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

export const DEFAULT_EXCLUDE_GLOBS = [
  '**/*.lock',
  'package-lock.json',
  'bun.lockb',
  'pnpm-lock.yaml',
  'yarn.lock',
  'Cargo.lock',
  'dist/**',
  'build/**',
  '.next/**',
  'out/**',
  'vendor/**',
  '**/generated/**',
  '**/__snapshots__/**',
  '**/*.snap',
  '**/*.generated.*',
  '**/migrations/**',
  '**/*.min.js',
  '**/*.map',
  '**/*.{svg,png,jpg,jpeg,gif,webp,ico,woff,woff2,ttf,otf,mp4,pdf,zip}',
];

export const DEFAULT_CONFIG = {
  prefix: null,
  requireIssue: true,
  allowChoreEscape: false,
  maxLines: 500,
  maxFiles: 40,
  maxTopLevelDirs: 3,
  minBodyChars: 120,
  overrideLabel: 'oversized-approved',
  exemptBranches: ['main', 'release', 'refactor', 'gh-pages'],
  excludeGlobs: DEFAULT_EXCLUDE_GLOBS,
};

const ALWAYS_EXEMPT_BRANCHES = ['main', 'release', 'refactor', 'gh-pages'];
const EXEMPT_BRANCH_PREFIXES = ['release/', 'dependabot/', 'renovate/'];
const REJECTED_TITLE_OPENERS = [
  'Added',
  'Fixed',
  'Updated',
  'Removed',
  'Changed',
  'Refactored',
  'Implemented',
];
const CONVENTIONAL_TYPES = 'build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test';
const EMOJI_RE = /[\p{Extended_Pictographic}\p{Regional_Indicator}\uFE0F\u200D]/u;

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

export function derivePrefix(repoName) {
  const cleanName = String(repoName).split('/').filter(Boolean).pop() || '';
  const parts = cleanName.split(/[-_\s]+/).filter(Boolean);
  const prefix = parts.length > 1
    ? parts.map((part) => part[0]).join('')
    : cleanName.slice(0, 3);
  const derived = prefix.toLowerCase().slice(0, 4);
  // A prefix must be 2 to 4 letters. A repo named `x` cannot supply that, and
  // failing later with "prefix must be 2-4 lowercase letters" would point at
  // the config rather than at the real cause, which is the name.
  if (derived.length === 1) return `${derived}${derived}`;
  return derived;
}

function isValidPrefix(prefix) {
  return typeof prefix === 'string' && /^[a-z]{2,4}$/.test(prefix);
}

function isExemptBranch(name, config) {
  return ALWAYS_EXEMPT_BRANCHES.includes(name)
    || (config.exemptBranches || []).includes(name)
    || EXEMPT_BRANCH_PREFIXES.some((prefix) => name.startsWith(prefix));
}

export function validateBranchName(name, config = DEFAULT_CONFIG) {
  const branch = String(name || '');
  if (isExemptBranch(branch, config)) {
    return { ok: true, exempt: true, failures: [], issueNumber: null };
  }

  if (config.allowChoreEscape && /^chore\/[a-z0-9]+(?:-[a-z0-9]+)*$/.test(branch)) {
    const slug = branch.slice('chore/'.length);
    if (slug.length >= 3 && slug.length <= 48) {
      return { ok: true, choreEscape: true, failures: [], issueNumber: null };
    }
  }

  // [1-9][0-9]* rather than [0-9]+: there is no issue #0, and a leading zero
  // makes cr-007-x and cr-7-x two branch names for one issue.
  const pattern = new RegExp(`^${config.prefix}-([1-9][0-9]*)-([a-z0-9]+(?:-[a-z0-9]+)*)$`);
  const match = pattern.exec(branch);
  if (!match) {
    const expected = `${config.prefix}-<issue>-<slug>`;
    return {
      ok: false,
      failures: [fail(
        'branch name',
        branch || '(empty)',
        `${expected}   e.g. ${config.prefix}-142-fix-onboarding-drop-off`,
        `git branch -m ${config.prefix}-<issue>-<slug>`,
      )],
      issueNumber: null,
    };
  }

  const slug = match[2];
  if (slug.length < 3 || slug.length > 48) {
    return {
      ok: false,
      failures: [fail(
        'branch slug',
        slug,
        '3-48 lowercase letters, numbers, and single hyphens',
        `git branch -m ${config.prefix}-${match[1]}-describe-the-change`,
      )],
      issueNumber: Number(match[1]),
    };
  }

  return { ok: true, failures: [], issueNumber: Number(match[1]) };
}

function subjectFromTitle(title) {
  const match = /^\[([A-Za-z]{2,4})-([0-9]+)\]\s+(.+)$/.exec(String(title || ''));
  return match ? { tagPrefix: match[1], tagIssue: Number(match[2]), subject: match[3] } : null;
}

// A PR title is whatever its author typed, and this output is read by agents
// that act on it and humans who paste it into a shell. Interpolating the title
// into a double-quoted command made `$(...)` and backticks live. Single-quote
// it, escaping embedded single quotes, so the text stays inert.
function shellFix(prefix, issueNumber, subject) {
  const safe = String(subject).replace(/'/g, "'\\''");
  return `gh pr edit --title '[${prefix.toUpperCase()}-${issueNumber}] ${safe}'`;
}

export function validateTitle(title, prefix, issueNumber) {
  let subject;
  const failures = [];

  if (issueNumber === null) {
    subject = String(title || '');
  } else {
    const parsed = subjectFromTitle(title);
    if (!parsed) {
      return {
        ok: false,
        failures: [fail(
          'PR title format',
          String(title || '(empty)'),
          `[${prefix.toUpperCase()}-${issueNumber}] Imperative subject`,
          `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`,
        )],
      };
    }

    if (parsed.tagPrefix !== prefix.toUpperCase()) {
      failures.push(fail(
        'PR title tag',
        `[${parsed.tagPrefix}-${parsed.tagIssue}]`,
        `[${prefix.toUpperCase()}-${issueNumber}]`,
        shellFix(prefix, issueNumber, parsed.subject),
      ));
    }
    if (parsed.tagIssue !== issueNumber) {
      failures.push(fail(
        'PR title issue',
        String(parsed.tagIssue),
        String(issueNumber),
        shellFix(prefix, issueNumber, parsed.subject),
      ));
    }
    subject = parsed.subject;
  }

  if (subject.length < 10 || subject.length > 50) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Describe the change"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Describe the change"`;
    failures.push(fail(
      'PR title subject length',
      `${subject.length} characters`,
      '10-50 characters',
      editCommand,
    ));
  }
  if (!/^\p{Lu}/u.test(subject)) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Fix the described issue"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`;
    failures.push(fail(
      'PR title capitalization',
      subject,
      'a subject that starts with a capital letter',
      editCommand,
    ));
  }
  if (/\.$/.test(subject)) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Fix the described issue"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`;
    failures.push(fail(
      'PR title punctuation',
      subject,
      'no trailing period',
      editCommand,
    ));
  }
  if (REJECTED_TITLE_OPENERS.some((word) => new RegExp(`^${word}\\b`, 'i').test(subject))
    || /^[A-Za-z][A-Za-z'-]*ing\b/i.test(subject)) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Fix the described issue"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`;
    failures.push(fail(
      'PR title mood',
      subject,
      'an imperative subject, not a past-tense or -ing opener',
      editCommand,
    ));
  }
  if (EMOJI_RE.test(String(title))) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Fix the described issue"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`;
    failures.push(fail(
      'PR title emoji',
      String(title),
      'no emoji',
      editCommand,
    ));
  }
  if (new RegExp(`^(?:${CONVENTIONAL_TYPES})(?:\\([^)]*\\))?!?:\\s+`, 'i').test(subject)) {
    const editCommand = issueNumber === null
      ? `gh pr edit --title "Fix the described issue"`
      : `gh pr edit --title "[${prefix.toUpperCase()}-${issueNumber}] Fix the described issue"`;
    failures.push(fail(
      'PR title prefix',
      subject,
      'no conventional-commit prefix',
      editCommand,
    ));
  }

  return { ok: failures.length === 0, failures };
}

// Every form GitHub actually treats as a closing reference. Three things are
// easy to miss and each one lets a second concern in unseen: all nine keywords
// rather than Closes and Fixes, an optional colon after the keyword
// (`Closes: #10`), and the cross-repo `owner/name#100` form. A reference into
// another repo still counts toward the one-reference rule, because it is still
// a second thing this pull request closes, but it can never satisfy the branch
// issue, so it is returned with its repo attached rather than as a bare number.
export function countClosingReferences(body) {
  const references = [];
  const pattern = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*(?:([\w.-]+\/[\w.-]+))?#([0-9]+)\b/gi;
  const visibleBody = String(body || '').replace(/<!--[\s\S]*?-->/g, '');
  for (const match of visibleBody.matchAll(pattern)) {
    references.push({ repo: match[1] || null, number: Number(match[2]) });
  }
  return references;
}

function sectionBody(body, heading) {
  const source = String(body || '');
  const headingPattern = new RegExp(`^##\\s+${heading}\\s*$`, 'im');
  const match = headingPattern.exec(source);
  if (!match) return null;
  const start = match.index + match[0].length;
  const rest = source.slice(start);
  const nextHeading = /^##\s+.+$/im.exec(rest);
  return (nextHeading ? rest.slice(0, nextHeading.index) : rest).trim();
}

function sentenceCount(text) {
  return String(text).split(/[.!?]+(?=\s|$)/).map((part) => part.trim()).filter(Boolean).length;
}

function hasCommandAndResult(text) {
  const lines = String(text).split('\n').map((line) => line.trim()).filter(Boolean);
  const command = lines.some((line) => /^(?:[$>`]|\*\s*)?(?:bun|npm|pnpm|yarn|node|deno|cargo|go|pytest|make|git|gh|npx|\.\/)[^\n]*/i.test(line));
  const result = /(?:->|\b(?:pass(?:ed)?|success(?:ful)?|clean|green|ok|verified|complete|no issues|exit(?:ed)?\s+0)\b|\d+\s+(?:tests?|checks?)\s+(?:pass|passed|successful))/i.test(text);
  return command && result;
}

export function validateBody(body, issueNumber, config = DEFAULT_CONFIG) {
  const source = String(body || '');
  const visibleSource = source.replace(/<!--[\s\S]*?-->/g, '');
  const failures = [];
  const visible = visibleSource.trim();
  if (visible.length < config.minBodyChars) {
    failures.push(fail(
      'PR body length',
      `${visible.length} characters`,
      `at least ${config.minBodyChars} characters`,
      'Add a short explanation under What, Why, and How I verified.',
    ));
  }

  const references = countClosingReferences(visibleSource);
  if (issueNumber === null) {
    if (references.length !== 0) {
      failures.push(fail(
        'closing issue references',
        `${references.length} references`,
        'no Closes #N or Fixes #N for a chore PR',
        'Remove the Closes reference, or use a numbered branch instead of a chore branch.',
      ));
    }
  } else {
    if (references.length !== 1) {
      failures.push(fail(
        'closing issue references',
        `${references.length} references`,
        `exactly one Closes #${issueNumber} or Fixes #${issueNumber}`,
        `Keep only: Closes #${issueNumber}`,
      ));
    } else if (references[0].repo || references[0].number !== issueNumber) {
      const got = references[0].repo ? `${references[0].repo}#${references[0].number}` : `#${references[0].number}`;
      failures.push(fail(
        'closing issue reference',
        got,
        `#${issueNumber}`,
        `Replace it with: Closes #${issueNumber}`,
      ));
    }
  }

  const what = sectionBody(visibleSource, 'What');
  const why = sectionBody(visibleSource, 'Why');
  const verified = sectionBody(visibleSource, 'How I verified');
  if (!what) {
    failures.push(fail('PR body section', 'missing ## What', '## What with one to three sentences', 'Add a ## What section.'));
  } else if (sentenceCount(what) < 1 || sentenceCount(what) > 3) {
    failures.push(fail('## What length', `${sentenceCount(what)} sentences`, 'one to three sentences', 'Rewrite ## What as one to three sentences.'));
  }
  if (!why) {
    failures.push(fail('PR body section', 'missing ## Why', '## Why with the problem and reason for the fix', 'Add a ## Why section.'));
  }
  if (!verified || /\b(?:N\/A|TODO|tested locally)\b/i.test(verified) || !hasCommandAndResult(verified)) {
    failures.push(fail(
      '## How I verified',
      verified || 'missing',
      'a command and its result, such as: bun test -> 214 passed',
      'Run a check and record the command and result under ## How I verified.',
    ));
  }
  if (!/^Assisted-by:\s*[^\s:]+:[^\s]+\s*$/im.test(visibleSource)) {
    failures.push(fail(
      'Assisted-by line',
      'missing',
      'Assisted-by: <agent>:<model>',
      'Add Assisted-by: <agent>:<model> in the body.',
    ));
  }

  return { ok: failures.length === 0, failures };
}

function expandBraces(pattern) {
  const open = pattern.indexOf('{');
  if (open === -1) return [pattern];
  let depth = 0;
  for (let index = open; index < pattern.length; index += 1) {
    if (pattern[index] === '{') depth += 1;
    if (pattern[index] === '}') {
      depth -= 1;
      if (depth === 0) {
        const inside = pattern.slice(open + 1, index);
        const choices = [];
        let choiceStart = 0;
        let choiceDepth = 0;
        for (let choiceIndex = 0; choiceIndex < inside.length; choiceIndex += 1) {
          if (inside[choiceIndex] === '{') choiceDepth += 1;
          if (inside[choiceIndex] === '}') choiceDepth -= 1;
          if (inside[choiceIndex] === ',' && choiceDepth === 0) {
            choices.push(inside.slice(choiceStart, choiceIndex));
            choiceStart = choiceIndex + 1;
          }
        }
        choices.push(inside.slice(choiceStart));
        if (choices.length < 2) return [pattern];
        const before = pattern.slice(0, open);
        const after = pattern.slice(index + 1);
        return choices.flatMap((choice) => expandBraces(`${before}${choice}${after}`));
      }
    }
  }
  return [pattern];
}

function globRegExp(pattern) {
  let source = '^';
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === '*') {
      if (pattern[index + 1] === '*') {
        while (pattern[index + 1] === '*') index += 1;
        if (pattern[index + 1] === '/') {
          index += 1;
          source += '(?:.*/)?';
        } else {
          source += '.*';
        }
      } else {
        source += '[^/]*';
      }
    } else {
      source += /[\\^$+?.()|[\]{}]/.test(character) ? `\\${character}` : character;
    }
  }
  return new RegExp(`${source}$`);
}

export function matchesGlob(filename, pattern) {
  const normalizedFilename = String(filename).replaceAll('\\', '/').replace(/^\.\//, '');
  return expandBraces(String(pattern)).some((expanded) => globRegExp(expanded).test(normalizedFilename));
}

export function summarizeFiles(files, config = DEFAULT_CONFIG) {
  let rawLines = 0;
  let countedLines = 0;
  let excludedLines = 0;
  let countedFiles = 0;
  let excludedFiles = 0;
  const topLevelDirs = new Set();
  for (const file of files) {
    const additions = Number(file.additions) || 0;
    const deletions = Number(file.deletions) || 0;
    const lines = additions + deletions;
    const filename = String(file.filename || '');
    rawLines += lines;
    if ((config.excludeGlobs || []).some((pattern) => matchesGlob(filename, pattern))) {
      excludedLines += lines;
      excludedFiles += 1;
      continue;
    }
    countedLines += lines;
    countedFiles += 1;
    topLevelDirs.add(filename.includes('/') ? filename.split('/')[0] : '.');
  }
  return {
    rawLines,
    countedLines,
    excludedLines,
    rawFiles: files.length,
    countedFiles,
    excludedFiles,
    topLevelDirs: [...topLevelDirs].sort(),
  };
}

export function checkSize(summary, config = DEFAULT_CONFIG, labels = []) {
  const failures = [];
  const warnings = [];
  const overridden = labels.includes(config.overrideLabel);
  if (!overridden && summary.countedLines > config.maxLines) {
    failures.push(fail(
      'PR size',
      `${summary.countedLines.toLocaleString()} counted lines`,
      `${config.maxLines.toLocaleString()} counted lines or fewer`,
      `Split the change, or ask the repo owner to add the ${config.overrideLabel} label.`,
    ));
  }
  if (!overridden && summary.countedFiles > config.maxFiles) {
    failures.push(fail(
      'changed files',
      `${summary.countedFiles} counted files`,
      `${config.maxFiles} counted files or fewer`,
      `Split the change, or ask the repo owner to add the ${config.overrideLabel} label.`,
    ));
  }
  if (summary.topLevelDirs.length > config.maxTopLevelDirs) {
    warnings.push(fail(
      'top-level directories',
      summary.topLevelDirs.join(', '),
      `${config.maxTopLevelDirs} or fewer`,
      'Split unrelated directories into separate pull requests.',
    ));
  }
  return { failures, warnings, overridden };
}

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  } catch {
    return process.cwd();
  }
}

function validateConfig(config) {
  if (!isValidPrefix(config.prefix)) throw new ConfigurationError('prefix must be 2-4 lowercase letters');
  if (typeof config.requireIssue !== 'boolean') throw new ConfigurationError('requireIssue must be true or false');
  if (typeof config.allowChoreEscape !== 'boolean') throw new ConfigurationError('allowChoreEscape must be true or false');
  for (const field of ['maxLines', 'maxFiles', 'maxTopLevelDirs', 'minBodyChars']) {
    if (!Number.isInteger(config[field]) || config[field] < 0) throw new ConfigurationError(`${field} must be a non-negative integer`);
  }
  if (typeof config.overrideLabel !== 'string' || !config.overrideLabel) throw new ConfigurationError('overrideLabel must be a non-empty string');
  if (!Array.isArray(config.exemptBranches) || !config.exemptBranches.every((value) => typeof value === 'string')) throw new ConfigurationError('exemptBranches must be an array of strings');
  if (!Array.isArray(config.excludeGlobs) || !config.excludeGlobs.every((value) => typeof value === 'string')) throw new ConfigurationError('excludeGlobs must be an array of strings');
  return config;
}

export function loadConfig(root = repoRoot(), repoName = repositoryName(root)) {
  const filename = path.join(root, '.github', 'pr-standards.json');
  let overrides = {};
  if (fs.existsSync(filename)) {
    try {
      overrides = JSON.parse(fs.readFileSync(filename, 'utf8'));
    } catch (error) {
      throw new ConfigurationError(`cannot read ${path.relative(root, filename)}: ${error.message}`);
    }
    if (!overrides || Array.isArray(overrides) || typeof overrides !== 'object') {
      throw new ConfigurationError(`${path.relative(root, filename)} must contain a JSON object`);
    }
  }
  const config = { ...DEFAULT_CONFIG, ...overrides };
  if (!Object.prototype.hasOwnProperty.call(overrides, 'prefix')) config.prefix = derivePrefix(repoName);
  if (!config.prefix) config.prefix = derivePrefix(repoName);
  validateConfig(config);
  return { config, path: filename, usedDefaultPrefix: !Object.prototype.hasOwnProperty.call(overrides, 'prefix') };
}

// Cached because apiRequest asks on every call, including once per page of a
// paginated file list. The answer cannot change inside one run.
const commandExistsCache = new Map();
function commandExists(command) {
  if (commandExistsCache.has(command)) return commandExistsCache.get(command);
  const result = commandExistsUncached(command);
  commandExistsCache.set(command, result);
  return result;
}

function commandExistsUncached(command) {
  try {
    execFileSync(command, ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

async function apiRequest(endpoint, repo) {
  if (commandExists('gh')) {
    try {
      const result = await execFileAsync('gh', ['api', `repos/${repo}/${endpoint}`], { maxBuffer: 20 * 1024 * 1024 });
      return JSON.parse(result.stdout);
    } catch (error) {
      const message = error.stderr?.trim() || error.message;
      throw new ApiError(`gh api failed for ${endpoint}: ${message}`, /\b404\b|not found/i.test(message) ? 404 : null);
    }
  }

  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new ConfigurationError('gh is not on PATH and GITHUB_TOKEN is not set');
  const response = await fetch(`https://api.github.com/repos/${repo}/${endpoint}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'pr-standards',
    },
  });
  if (!response.ok) throw new ApiError(`GitHub API returned ${response.status} for ${endpoint}`, response.status);
  return response.json();
}

async function fetchPullFiles(repo, number) {
  const files = [];
  for (let page = 1; ; page += 1) {
    const pageFiles = await apiRequest(`pulls/${number}/files?per_page=100&page=${page}`, repo);
    if (!Array.isArray(pageFiles)) throw new ApiError(`GitHub returned an invalid file list for pull request ${number}`);
    files.push(...pageFiles);
    if (pageFiles.length < 100) return files;
  }
}

function currentBranch() {
  try {
    return execFileSync('git', ['branch', '--show-current'], { encoding: 'utf8' }).trim();
  } catch {
    throw new ConfigurationError('cannot read the current branch; pass a branch name explicitly');
  }
}

// The directory name is not the repo name. A worktree is checked out to a
// directory the author picked, so `scripts` becomes `scripts-pr-standards` and
// the derived prefix silently changes with it. Ask something that knows: the
// CI environment first, then the remote. The basename is the last resort.
// Split on both `/` and `:` so an SSH remote (git@github.com:owner/repo.git)
// resolves the same as an HTTPS one.
export function repositoryNameWithSource(root) {
  if (process.env.GITHUB_REPOSITORY) {
    return { name: process.env.GITHUB_REPOSITORY.split('/').pop(), source: 'GITHUB_REPOSITORY' };
  }
  try {
    const remote = execFileSync('git', ['-C', root, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    const name = remote.replace(/\.git$/, '').split(/[/:]/).pop();
    if (name) return { name, source: 'origin remote' };
  } catch {
    // No remote, or not a git repo. Fall through to the directory name.
  }
  // Last resort, and the weakest: a worktree lives in a directory the author
  // named, so this can disagree with the real repo. Callers surface the source
  // so a prefix derived this way is visible rather than assumed.
  return { name: path.basename(root), source: 'directory name' };
}

export function repositoryName(root) {
  return repositoryNameWithSource(root).name;
}

function formatNumber(value) {
  return Number(value).toLocaleString('en-US');
}

function humanFailure(item, prefix = '      ') {
  return `${prefix}got:      ${item.got}\n${prefix}expected: ${item.expected}\n${prefix}fix:      ${item.fix}`;
}

function outputHuman(result) {
  const prefixLine = result.provenance
    ? `Using prefix: ${result.prefix} (${result.provenance})`
    : `Using prefix: ${result.prefix}`;
  const lines = [prefixLine];
  for (const pass of result.passes || []) lines.push(`PASS  ${pass}`);
  for (const item of result.failures || []) lines.push(`FAIL  ${item.check}\n${humanFailure(item)}`);
  for (const item of result.warnings || []) lines.push(`WARN  ${item.check}\n${humanFailure(item)}`);
  if (result.size) {
    const excluded = result.size.excludedLines
      ? ` (${formatNumber(result.size.rawLines)} raw; ${formatNumber(result.size.excludedLines)} excluded as generated)`
      : ` (${formatNumber(result.size.rawLines)} raw)`;
    lines.push(`SIZE  ${formatNumber(result.size.countedLines)} counted lines${excluded}; ${result.size.countedFiles} counted files`);
  }
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

function parseArgs(argv) {
  const args = [...argv];
  const json = args.includes('--json');
  const filtered = args.filter((arg) => arg !== '--json');
  if (filtered.includes('--help') || filtered.includes('-h')) return { help: true };
  if (filtered.includes('--selfcheck')) return { selfcheck: true };
  const mode = filtered.shift();
  if (!mode || !['branch', 'precheck', 'pr'].includes(mode)) throw new ConfigurationError('usage: pr-standards branch [name], precheck --branch X, or pr --repo owner/name --number N');
  const options = { mode, json, positional: [] };
  for (let index = 0; index < filtered.length; index += 1) {
    const arg = filtered[index];
    if (arg === '--branch' || arg === '--title' || arg === '--repo' || arg === '--number') {
      const value = filtered[index + 1];
      if (!value || value.startsWith('--')) throw new ConfigurationError(`${arg} requires a value`);
      options[arg.slice(2)] = value;
      index += 1;
    } else if (arg.startsWith('--')) {
      throw new ConfigurationError(`unknown option: ${arg}`);
    } else {
      options.positional.push(arg);
    }
  }
  return options;
}

function usage() {
  return `Usage:
  pr-standards branch [name]
  pr-standards precheck --branch X [--title Y]
  pr-standards pr --repo owner/name --number N
  pr-standards --selfcheck

Add --json to any command for machine-readable output.`;
}

async function runBranch(options) {
  const root = repoRoot();
  const named = repositoryNameWithSource(root);
  const { config, path: configPath } = loadConfig(root, named.name);
  // Say where the prefix came from. A prefix guessed from a directory name is
  // the one most likely to be wrong, so it must not look identical to one read
  // from the repo's own config.
  const provenance = fs.existsSync(configPath)
    ? 'from .github/pr-standards.json'
    : `derived from ${named.source}`;
  if (options.branch || options.title || options.repo || options.number) throw new ConfigurationError('branch accepts only one optional branch name');
  const branch = options.positional[0] || currentBranch();
  if (options.positional.length > 1) throw new ConfigurationError('branch accepts one optional name');
  const branchResult = validateBranchName(branch, config);
  return finish({
    mode: 'branch',
    prefix: config.prefix,
    provenance,
    failures: branchResult.failures,
    warnings: [],
    passes: branchResult.ok ? [`branch name: ${branch}${branchResult.exempt ? ' (exempt)' : ''}`] : [],
  }, options.json);
}

async function runPrecheck(options) {
  const root = repoRoot();
  const named = repositoryNameWithSource(root);
  const { config, path: configPath } = loadConfig(root, named.name);
  // Say where the prefix came from. A prefix guessed from a directory name is
  // the one most likely to be wrong, so it must not look identical to one read
  // from the repo's own config.
  const provenance = fs.existsSync(configPath)
    ? 'from .github/pr-standards.json'
    : `derived from ${named.source}`;
  if (!options.branch) throw new ConfigurationError('precheck requires --branch');
  if (options.positional.length > 0 || options.repo || options.number) throw new ConfigurationError('precheck accepts --branch and optional --title only');
  const branchResult = validateBranchName(options.branch, config);
  const failures = [...branchResult.failures];
  const passes = branchResult.ok ? [`branch name: ${options.branch}`] : [];
  if (options.title) {
    if (!branchResult.exempt) {
      if (branchResult.issueNumber !== null || branchResult.choreEscape) {
        const titleResult = validateTitle(options.title, config.prefix, branchResult.issueNumber);
        failures.push(...titleResult.failures);
        if (titleResult.ok) passes.push('PR title');
      } else {
        failures.push(fail('PR title', options.title, 'a valid branch issue number before checking the title', 'Fix the branch name first.'));
      }
    }
  }
  return finish({ mode: 'precheck', prefix: config.prefix, provenance, failures, warnings: [], passes }, options.json);
}

async function fetchRemoteConfig(repo, defaultPrefix, ref) {
  try {
    const query = ref ? `?ref=${encodeURIComponent(ref)}` : '';
    const response = await apiRequest(`contents/.github/pr-standards.json${query}`, repo);
    if (response.content && response.encoding === 'base64') {
      const content = Buffer.from(response.content, 'base64').toString('utf8');
      const overrides = JSON.parse(content);
      if (!overrides || Array.isArray(overrides) || typeof overrides !== 'object') {
        throw new ConfigurationError(`${repo} .github/pr-standards.json must contain a JSON object`);
      }
      const config = { ...DEFAULT_CONFIG, ...overrides };
      if (!Object.prototype.hasOwnProperty.call(overrides, 'prefix')) config.prefix = defaultPrefix;
      if (!config.prefix) config.prefix = defaultPrefix;
      validateConfig(config);
      return { config, provenance: `from ${repo} .github/pr-standards.json${ref ? ` @ ${ref}` : ''}` };
    }
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      // Fallback to default
    } else if (error instanceof SyntaxError) {
      throw new ConfigurationError(`${repo} .github/pr-standards.json contains invalid JSON: ${error.message}`);
    } else {
      throw error;
    }
  }
  const config = { ...DEFAULT_CONFIG, prefix: defaultPrefix };
  validateConfig(config);
  return { config, provenance: `derived; ${repo} has no config` };
}

async function runPr(options) {
  if (options.positional.length > 0 || options.branch || options.title) throw new ConfigurationError('pr accepts --repo and --number only');
  if (!options.repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repo)) throw new ConfigurationError('pr requires --repo owner/name');
  if (!options.number || !/^[0-9]+$/.test(options.number) || Number(options.number) < 1) throw new ConfigurationError('pr requires a positive --number');
  const repoName = options.repo.split('/').pop();
  let config;
  let provenance;
  
  // In CI, GITHUB_REPOSITORY is the local checkout which is the target repo, so we can use loadConfig
  const number = Number(options.number);
  const pull = await apiRequest(`pulls/${number}`, options.repo);

  // Read the config from the BASE branch, never from the checkout. In CI the
  // checkout is the pull request's own head, so a PR that edits
  // .github/pr-standards.json would be judged by the rules it just wrote: set
  // excludeGlobs to ["**"], or maxLines to a million, and the check that exists
  // to catch exactly that change waves it through. The base branch holds the
  // last rules that survived review, so it is the only honest thing to judge
  // against.
  const baseRef = pull.base?.ref;
  const loaded = await fetchRemoteConfig(options.repo, derivePrefix(repoName), baseRef);
  config = loaded.config;
  provenance = loaded.provenance;
  const branch = pull.head?.ref || '';
  const branchResult = validateBranchName(branch, config);
  const failures = [...branchResult.failures];
  const warnings = [];
  const passes = [];
  if (branchResult.ok) passes.push(`branch name: ${branch}`);

  if (branchResult.issueNumber !== null && config.requireIssue) {
    try {
      const issue = await apiRequest(`issues/${branchResult.issueNumber}`, options.repo);
      if (issue.pull_request) {
        failures.push(fail('branch issue', `#${branchResult.issueNumber} is a pull request`, 'an existing open issue', `Create or select an open issue, then rename the branch.`));
      } else if (issue.state !== 'open') {
        failures.push(fail('branch issue', `#${branchResult.issueNumber} is ${issue.state}`, 'an existing open issue', `Reopen #${branchResult.issueNumber}, or create a new branch for an open issue.`));
      } else {
        passes.push(`issue #${branchResult.issueNumber} is open`);
      }
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        failures.push(fail('branch issue', `#${branchResult.issueNumber} was not found`, 'an existing open issue', `Create or select an open issue, then rename the branch.`));
      } else {
        throw error;
      }
    }
  }
  if (!branchResult.exempt) {
    const titleResult = validateTitle(pull.title || '', config.prefix, branchResult.issueNumber);
    failures.push(...titleResult.failures);
    if (titleResult.ok) passes.push('PR title');
    const bodyResult = validateBody(pull.body || '', branchResult.issueNumber, config);
    failures.push(...bodyResult.failures);
    if (bodyResult.ok) passes.push('PR body');
  }

  const files = await fetchPullFiles(options.repo, number);
  // GitHub's pull-request files endpoint stops at 3000 entries and gives no
  // signal that it did. Comparing against the count the pull request itself
  // reports is the only way to notice, and a size check that silently measured
  // part of a diff would be worse than one that admits it cannot.
  if (typeof pull.changed_files === 'number' && files.length < pull.changed_files) {
    warnings.push(fail(
      'diff truncated by the API',
      `${files.length} of ${pull.changed_files} changed files`,
      'every changed file',
      'GitHub returns at most 3000 files per pull request. Treat the size below as a floor and split the PR.',
    ));
  }
  if (files.some((file) => file.filename === '.github/pr-standards.json')) {
    warnings.push(fail(
      'PR edits the standard itself',
      '.github/pr-standards.json is in this diff',
      'rules that already survived review',
      `Judged against ${baseRef || 'the base branch'}, not this PR's copy. Review the config change on its own merits.`,
    ));
  }
  const summary = summarizeFiles(files, config);
  const labels = (pull.labels || []).map((label) => typeof label === 'string' ? label : label.name).filter(Boolean);
  const sizeResult = checkSize(summary, config, labels);
  failures.push(...sizeResult.failures);
  warnings.push(...sizeResult.warnings);
  if (sizeResult.overridden) passes.push(`size caps overridden by ${config.overrideLabel}`);

  return finish({
    mode: 'pr',
    repo: options.repo,
    number,
    prefix: config.prefix,
    provenance,
    branch,
    issue: branchResult.issueNumber,
    failures,
    warnings,
    passes,
    size: summary,
    overrideLabel: config.overrideLabel,
  }, options.json);
}

export async function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) {
      process.stdout.write(`${usage()}\n`);
      return 0;
    }
    if (options.selfcheck) {
      const testFile = fileURLToPath(new URL('./pr-standards.test.mjs', import.meta.url));
      const result = spawnSync(process.execPath, ['--test', testFile], { stdio: 'inherit' });
      return result.status ?? 1;
    }
    if (options.mode === 'branch') return await runBranch(options);
    if (options.mode === 'precheck') return await runPrecheck(options);
    return await runPr(options);
  } catch (error) {
    const result = {
      clean: false,
      failures: [fail(error.name === 'ConfigurationError' ? 'configuration' : 'GitHub API', error.message, 'a valid configuration and accessible repository', 'Fix the command, configuration, or GitHub authentication.')],
      warnings: [],
    };
    const json = options?.json || argv.includes('--json');
    if (json) outputJson(result);
    else {
      const item = result.failures[0];
      process.stderr.write(`FAIL  ${item.check}\n${humanFailure(item)}\n`);
    }
    return error.name === 'ConfigurationError' ? 2 : 1;
  }
}
