import fs from 'node:fs';
import path from 'node:path';
import { execFile, execFileSync, spawnSync } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const PREFIX_REGISTRY_PATH = fileURLToPath(new URL('./repo-prefixes.json', import.meta.url));

// Banned AI attribution names in Co-authored-by trailers. These are matched as
// whole words in the author name field so "Pia" does not match pi and "Gupta"
// does not match GPT. vibecodereview is explicitly exempt.
export const DEFAULT_BANNED_COMMIT_TRAILERS = [
  'Claude',
  'Codex',
  'Gemini',
  'Kimi',
  'Muse',
  'pi',
  'ChatGPT',
  'GPT',
  'Copilot',
  'Cursor',
  'Devin',
  'Anthropic',
  'OpenAI',
];

export const DEFAULT_EXCLUDE_GLOBS = [
  // Anchored at any depth, not just the repo root. A monorepo keeps a lockfile
  // per workspace, and an unanchored pattern counted apps/*/package-lock.json
  // against the 500-line cap -- so a dependency bump failed the size check on
  // thousands of generated lines nobody reads.
  '**/*.lock',
  '**/package-lock.json',
  '**/bun.lockb',
  '**/pnpm-lock.yaml',
  '**/yarn.lock',
  '**/Cargo.lock',
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
  bannedCommitTrailers: DEFAULT_BANNED_COMMIT_TRAILERS,
  exemptBranches: ['main', 'release', 'refactor', 'gh-pages'],
  excludeGlobs: DEFAULT_EXCLUDE_GLOBS,
  requireProof: true,
  // Warn first, then ratchet. A fleet where no repo runs its tests in CI would
  // go red everywhere on the day this became a failure, and a standard that
  // does that on its first day gets switched off.
  requireAttributableProof: false,
  uiGlobs: [
    '**/*.tsx', '**/*.jsx', '**/*.vue', '**/*.svelte', '**/*.css', '**/*.scss',
    '**/*.html', '**/components/**', '**/app/**/page.*', '**/pages/**',
  ],
  uiExcludeGlobs: [
    '**/*.test.*', '**/*.spec.*', '**/__tests__/**', '**/*.stories.*',
  ],
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

// Escape a literal string so it is safe in a new RegExp. Used for matching
// banned trailer names as whole words.
function escapeRegex(string) {
  return String(string).replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

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
  const rawName = String(repoName).split('/').filter(Boolean).pop() || '';
  // Strip anything that is not a letter before deriving. A prefix must be 2 to
  // 4 lowercase letters, so a name like `3d-tools` derived `3t` and then failed
  // validation on every single invocation, with a message about the config
  // rather than about the name that caused it.
  const cleanName = rawName.replace(/[^A-Za-z-_\s]/g, '');
  const parts = cleanName.split(/[-_\s]+/).filter(Boolean);
  const prefix = parts.length > 1
    ? parts.map((part) => part[0]).join('')
    : cleanName.slice(0, 3);
  // A prefix must be 2 to 4 letters. A repo named `x`, one made entirely of
  // digits, or one that is all separators cannot supply that. Failing later with
  // "prefix must be 2-4 lowercase letters" would point at the config rather than
  // at the real cause, which is the name, so give a usable answer and let the
  // repo override it. Keep only letters here: `a-` and `---` are the right
  // length by accident and would otherwise sail past both fallbacks and be
  // rejected downstream by exactly the message this is meant to avoid.
  const letters = prefix.toLowerCase().replace(/[^a-z]/g, '').slice(0, 4);
  if (letters.length === 0) return 'zz';
  const derived = letters.length === 1 ? `${letters}${letters}` : letters;
  return isValidPrefix(derived) ? derived : 'zz';
}

function isValidPrefix(prefix) {
  return typeof prefix === 'string' && /^[a-z]{2,4}$/.test(prefix);
}

function registryPrefix(repoName) {
  try {
    const registry = JSON.parse(fs.readFileSync(PREFIX_REGISTRY_PATH, 'utf8'));
    if (!registry || Array.isArray(registry) || typeof registry !== 'object') return null;
    const prefix = registry[repoName];
    return isValidPrefix(prefix) ? prefix : null;
  } catch {
    // A broken registry must not prevent a new repo from using derivation.
    return null;
  }
}

function resolveFallbackPrefix(repoName) {
  const registered = registryPrefix(repoName);
  return registered
    ? { prefix: registered, source: 'registry' }
    : { prefix: derivePrefix(repoName), source: 'derived' };
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
  const match = /^\[([A-Za-z]{2,4})-([1-9][0-9]*)\]\s+(.+)$/.exec(String(title || ''));
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

// The documented escape hatch, in the one form the checker accepts. It lives in
// a constant because two rules read it: the body check below must not mistake it
// for a refusal to answer, and the proof check must honour it. Two copies of
// this pattern would eventually disagree, and the disagreement would look like
// a lazy body rather than a drifted regex.
const PROOF_NA_LINE = /^\s*Proof:\s*n\/a\s*[—–-]\s*(\S.*)\s*$/i;

function hasCommandAndResult(text) {
  const lines = String(text).split('\n').map((line) => line.trim()).filter(Boolean);
  // The word boundary goes AFTER the command name, not before it. Without it
  // `bun` matched inside `Bundle`, so "Bundle was verified" satisfied both the
  // command and the result check while naming no command at all.
  // Order in the alternation does NOT matter, despite what an earlier comment
  // here claimed: a failed `\b` makes the engine backtrack and try the other
  // branches, so `bun|bunx` matches "bunx" exactly as `bunx|bun` does. What
  // fixed the `bunx` failure was adding the name, not moving it. The longer
  // names are still written first, because that reads as intent.
  //
  // `python3` and `python` are here because the checker itself shells to
  // `python3` and three of its test suites are `python3` scripts, yet the list
  // named neither: a pull request whose evidence was a real `python3` run
  // failed the rule, and the author met the regex by prefixing a pointless
  // `node -e` to the command that had already run.
  const command = lines.some((line) => /^(?:[$>`]\s*|\*\s*)?(?:bunx|bun|npm|pnpm|yarn|node|deno|cargo|go|pytest|python3|python|make|git|gh|npx|\.\/)\b[^\n]*/i.test(line));
  const result = /(?:->|\b(?:pass(?:ed)?|success(?:ful)?|clean|green|ok|verified|complete|no issues|exit(?:ed)?\s+0)\b|\d+\s+(?:tests?|checks?)\s+(?:pass|passed|successful))/i.test(text);
  return command && result;
}

// Proof helpers — an agent can type "tested locally" for free; a screenshot
// or a real command output costs work, so proof is the part worth checking.
// A user-attachments URL is the only proof that does not bloat the repo.
//
// Fenced code remains outside this check's scope. Inline code is allowed to
// carry a real URL, so its backticks must not become part of the asset id.
function countUserAttachments(body) {
  const visible = String(body || '').replace(/<!--[\s\S]*?-->/g, '');
  // No indentation filter here, deliberately. Four leading spaces mark an
  // indented code block only OUTSIDE a list; inside one they are continuation
  // content that renders normally, and a line-start test cannot tell the two
  // apart. Filtering on indentation alone rejected an attachment written under
  // a bullet -- an ordinary way to caption before and after -- which is a false
  // failure on honest work. Answering it needs real block containment, which is
  // the body reader's job (#143), not a second implementation here. Until then
  // an inert URL counts, and that is the safe direction to be wrong.
  const text = visible;
  // Backticks are Markdown syntax, not URL characters. Angle brackets mark
  // the before/after placeholders in this convention's own docs; counting
  // them would let copied examples through as real assets.
  const matches = text.match(/https:\/\/github\.com\/user-attachments\/assets\/[^\s"'\x60\)\]<>]+/g);
  if (!matches) return 0;
  // Distinct assets, not link count. The threshold asks for before AND after,
  // so the same image pasted twice is one image and must not clear it -- and a
  // query string or fragment on the same asset is still that asset. The match
  // itself excludes Markdown delimiters, quotes and whitespace, but not
  // sentence punctuation, so a bare URL followed by a period or comma in prose
  // keeps that character; strip it too or the same asset pasted once inside
  // markdown and once in prose counts as two.
  return new Set(matches.map((url) => url.split(/[?#]/)[0].replace(/[.,;:!?]+$/, ''))).size;
}

function hasValidProofNa(body) {
  const visible = String(body || '').replace(/<!--[\s\S]*?-->/g, '');
  const lines = visible.split('\n');
  for (const line of lines) {
    const match = PROOF_NA_LINE.exec(line);
    if (match && match[1].trim().length >= 20) return true;
  }
  return false;
}

// A command and its result cost nothing to type whether or not the command
// ran -- `bun test -> 214 passed` reads identically either way, and nothing
// mechanical can tell the two apart from text alone. What CAN be checked is
// whether the claim points to something outside the body: a run GitHub itself
// executed, or an attachment that took a real screen capture to produce. The
// documented `Proof: n/a` hatch counts too, because it already carries its own
// burden (a stated reason, judged by the review council) that a bare command
// claim does not.
// The lookahead after \d+ names what CAN follow a real run ID, rather than
// denying one more character at a time. A deny-list already failed once here:
// the first version excluded only letters and digits, so `runs/123not-a-run`
// was closed but `runs/123_not-a-run` and `runs/123-not-a-run` still matched,
// because `_` and `-` are neither (#210). GitHub only ever follows the numeric
// ID with end-of-string, a nested path (`/job/987`), a query string (`?...`),
// a fragment (`#...`), whitespace, or ordinary sentence/markdown-closing
// punctuation -- never a bare word character or a hyphen.
//
// Sentence punctuation (`.,;:!`) needs its own inner check: it is only a real
// boundary when it actually ends the clause (followed by whitespace or
// end-of-string). Treating it as a boundary unconditionally let a fake run ID
// glue arbitrary text on through a single dot or comma -- `runs/123.not-a-run`
// -- because the lookahead only inspected the one character right after the
// digits and never looked past it. Path/query/fragment continuations are
// consumed explicitly instead, so only those get to carry trailing characters.
//
// Closing delimiters (a paren, bracket, quote, backtick) can sit between the
// punctuation and the whitespace/end that terminates it -- a parenthetical
// remark ending in a full sentence closes as `...runs/123456789.)`, not
// `...runs/123456789).`. Requiring whitespace/end immediately after the
// punctuation rejected that real shape outright, because closing delimiters
// are exactly the case where more (harmless) characters legitimately follow
// the period before the line actually ends.
const ACTIONS_RUN_URL = /https:\/\/github\.com\/[^\s\/]+\/[^\s\/]+\/actions\/runs\/\d+(?:[\/?#][^\s"'\x60\)\]<>]*)?(?=$|[\s"'\x60\)\]<>]|[.,;:!]+[\x60"'\)\]<>]*(?=$|\s))/;

function hasExternalProofEvidence(verifiedSection) {
  if (countUserAttachments(verifiedSection) > 0) return true;
  if (ACTIONS_RUN_URL.test(verifiedSection)) return true;
  if (hasValidProofNa(verifiedSection)) return true;
  return false;
}

export function isUiFile(filename, config = DEFAULT_CONFIG) {
  const uiGlobs = config.uiGlobs || [];
  const uiExcludeGlobs = config.uiExcludeGlobs || [];
  const matchesUi = uiGlobs.some((pattern) => matchesGlob(filename, pattern));
  if (!matchesUi) return false;
  const excluded = uiExcludeGlobs.some((pattern) => matchesGlob(filename, pattern));
  return !excluded;
}

export function hasUiDiff(files, config = DEFAULT_CONFIG) {
  if (!Array.isArray(files) || files.length === 0) return false;
  // A rename that moves a UI file to a name the globs no longer match (an
  // extension swap, or out of components/**) still ships whatever content
  // change rode along with the rename. The pre-rename name is UI evidence
  // GitHub already gives us on the same file object; checking only the new
  // name would let a rename silently clear the proof requirement.
  return files.some((file) => {
    if (typeof file !== 'object' || file === null) return isUiFile(String(file || ''), config);
    return isUiFile(String(file.filename || ''), config) || isUiFile(String(file.previous_filename || ''), config);
  });
}

const PROOF_MEDIA_EXTENSIONS = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'mp4', 'mov', 'webm']);
// Keep directory signals separate from filename signals. Mixing them makes a
// future exemption easy to apply to the wrong kind of path rule.
const PROOF_MEDIA_DIR_GLOBS = [
  'screenshot*/**',
  '**/screenshots/**',
  'proof*/**',
];
const PROOF_MEDIA_NAME_GLOBS = [
  '**/*before*',
  '**/*after*',
  '**/*demo-recording*',
];
const PROOF_MEDIA_ASSET_DIR_GLOBS = ['public/**', '**/assets/**'];

function isProofMediaPath(filename) {
  const normalized = String(filename).replaceAll('\\', '/').replace(/^\.\//, '');
  if (!normalized.includes('/')) return true;
  // The asset-root exemption wins over every other signal, including a
  // proof-named directory. `public/screenshots/` is a completely ordinary
  // product pattern -- a docs site or a landing page serving a screenshot
  // gallery -- and flagging it rejects honest work, which is the one direction
  // this check must not be wrong in. Someone committing pull request media
  // puts it at the repo root or in `proof/`, not under a served asset root.
  if (PROOF_MEDIA_ASSET_DIR_GLOBS.some((pattern) => matchesGlob(normalized, pattern))) return false;
  if (PROOF_MEDIA_DIR_GLOBS.some((pattern) => matchesGlob(normalized, pattern))) return true;
  return PROOF_MEDIA_NAME_GLOBS.some((pattern) => matchesGlob(normalized, pattern));
}

export function isCommittedProofMedia(file) {
  const filename = String(file.filename || '');
  if (!filename) return false;
  // Only files ADDED by the diff are proof media committed by mistake. Treating
  // modified or renamed files as added rejects honest product-asset changes.
  // Treating a missing status as non-added lets committed media through when a
  // caller lacks a GitHub payload.
  // When no status is supplied, treat the file as added so unit tests can still
  // exercise the glob and extension rules without a GitHub payload.
  if (Object.prototype.hasOwnProperty.call(file, 'status') && file.status !== 'added') return false;
  const lower = filename.toLowerCase();
  const dot = lower.lastIndexOf('.');
  if (dot === -1) return false;
  const ext = lower.slice(dot + 1);
  if (!PROOF_MEDIA_EXTENSIONS.has(ext)) return false;
  return isProofMediaPath(filename);
}

// Proof is one question — does this pull request show the work it did — so it
// is one check, even though its evidence comes from three places: the body, the
// files, and the labels. Splitting it across validateBody and checkSize made
// each caller responsible for suppressing the other's half.
export function checkProof(body, files, config = DEFAULT_CONFIG) {
  const failures = [];
  const warnings = [];
  // No label clears this. #114 removed the size cap's override label because an
  // agent can apply its own label, and that argument applies unchanged here --
  // a proof requirement an agent can waive is not a requirement. The only
  // escape is a stated reason in the body, which the review council judges.
  if (config.requireProof === false) return { failures, warnings };

  for (const file of files || []) {
    if (!isCommittedProofMedia(file)) continue;
    failures.push(fail(
      'committed proof media',
      String(file.filename || ''),
      'proof media uploaded to GitHub user-attachments, not committed',
      'Remove it from the commit and upload it to https://uploads.github.com/user-attachments/assets instead. A screenshot lives in the repo history forever; a link does not.',
    ));
  }

  // A visual change reviewed only as code is reviewed only half. The escape
  // hatch is a stated reason, which the review council judges — the checker
  // cannot tell a real one from "n/a". Both live under ## How I verified per
  // the docs, so an attachment or hatch line pasted under ## What or ## Why
  // does not count: the evidence belongs where the reviewer is told to look.
  const verifiedSection = sectionBody(body, 'How I verified') || '';
  let uiProofFailed = false;
  if (hasUiDiff(files || [], config) && !hasValidProofNa(verifiedSection)) {
    const count = countUserAttachments(verifiedSection);
    if (count === 0) {
      uiProofFailed = true;
      failures.push(fail(
        'proof of a visible change',
        'no user-attachments URL in the body',
        'before and after media, or `Proof: n/a — <reason>`',
        'Capture the screen before and after, upload both to GitHub user-attachments, and embed them under "How I verified".',
      ));
    } else if (count === 1) {
      warnings.push(fail(
        'proof of a visible change',
        'one user-attachments URL',
        'before and after',
        'One image shows the result, not the change. Add the other side.',
      ));
    }
  }

  // Evidence has to be attributable, not merely present. A command claim like
  // `bun test -> 214 passed` costs an agent nothing to write, and it reads
  // identically whether or not it ran. What can be checked is whether the claim
  // points to something outside the body: a run GitHub itself executed, or an
  // attachment that took a real capture to produce.
  //
  // Silent when the visible-change check above already failed: that failure
  // already names the same gap for a UI diff, and two findings for one missing
  // capture reads as two gaps rather than one.
  //
  // Warn by default (#85). Most repos in the fleet do not yet run their own
  // tests in CI, so failing every PR whose proof lives only in prose would turn
  // the whole fleet red on day one and get the standard switched off. A repo
  // ratchets this to a failure with `requireAttributableProof` once its tests
  // run in CI and a run link is something its own agents can always produce.
  if (!uiProofFailed && hasCommandAndResult(verifiedSection) && !hasExternalProofEvidence(verifiedSection)) {
    const finding = fail(
      'attributable proof',
      'a command and result claimed in text, nothing outside the body to check it against',
      'a linked Actions run, an attachment, or `Proof: n/a — <reason>`',
      'A line like `bun test -> 214 passed` reads the same whether or not it ran. Link the Actions run that produced it, attach a screenshot, or state a `Proof: n/a` reason.',
    );
    if (config.requireAttributableProof) failures.push(finding);
    else warnings.push(finding);
  }
  return { failures, warnings };
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
  // The N/A guard exists to reject a section that refuses to answer. The
  // documented proof escape hatch, `Proof: n/a — <reason>`, is an answer, and
  // the docs say to write it in this very section — so the guard failed every
  // pull request that used the hatch correctly, and blamed lazy verification
  // rather than naming the line. Swap a valid hatch line for its reason before
  // the guard runs, rather than dropping the line outright: a reason of just
  // "TODO" or "N/A" is still a refusal, and the guard must still see it.
  // A bare N/A, a TODO, "tested locally", and a `Proof: n/a` with no reason all
  // still fail.
  // Quoted text is not a claim. A body that explains the rule inside the section
  // the rule reads — "a bare `N/A`, a `TODO`, \"tested locally\"" — was failed by
  // its own explanation, and the message named nothing. Drop fenced blocks and
  // inline code before testing for a refusal to answer. Only this test is
  // affected: hasCommandAndResult still reads the raw section, because a command
  // and its output belong in a code block.
  const claimed = verified === null ? null
    : verified
      .replace(/^ {0,3}(`{3,}|~{3,})[\s\S]*?^ {0,3}\1[ \t]*$/gm, '')
      .replace(/`[^`\n]*`/g, '')
      .split('\n').map((line) => {
        const hatch = PROOF_NA_LINE.exec(line);
        return hatch ? hatch[1] : line;
      }).join('\n');
  if (!verified || /\b(?:N\/A|TODO|tested locally)\b/i.test(claimed) || !hasCommandAndResult(verified)) {
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
    // Only real directories count. Treating a root file as a directory named
    // '.' made README.md plus three directories look like four.
    if (filename.includes('/')) topLevelDirs.add(filename.split('/')[0]);
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

// The cap has no label escape. Every escape from a design constraint becomes
// the path: an agent told it may ask for a label asks for the label, rather
// than decomposing the work, which is the one thing the cap exists to force.
//
// The remaining escape is the right one and lives outside this checker: a
// person merges past a red check. That takes a deliberate act by a human on a
// named pull request. It cannot be requested in a body, and it leaves a record.
export function checkSize(summary, config) {
  config ??= DEFAULT_CONFIG;
  const failures = [];
  const warnings = [];
  if (summary.countedLines > config.maxLines) {
    failures.push(fail(
      'PR size',
      `${summary.countedLines.toLocaleString()} counted lines`,
      `${config.maxLines.toLocaleString()} counted lines or fewer`,
      'Split the change. There is no label that clears this.',
    ));
  }
  if (summary.countedFiles > config.maxFiles) {
    failures.push(fail(
      'changed files',
      `${summary.countedFiles} counted files`,
      `${config.maxFiles} counted files or fewer`,
      'Split the change. There is no label that clears this.',
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
  return { failures, warnings };
}

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  } catch {
    return process.cwd();
  }
}

export function validateConfig(config) {
  if (!isValidPrefix(config.prefix)) throw new ConfigurationError('prefix must be 2-4 lowercase letters');
  if (typeof config.requireIssue !== 'boolean') throw new ConfigurationError('requireIssue must be true or false');
  if (typeof config.allowChoreEscape !== 'boolean') throw new ConfigurationError('allowChoreEscape must be true or false');
  for (const field of ['maxLines', 'maxFiles', 'maxTopLevelDirs', 'minBodyChars']) {
    if (!Number.isInteger(config[field]) || config[field] < 0) throw new ConfigurationError(`${field} must be a non-negative integer`);
  }
  if (!Array.isArray(config.bannedCommitTrailers) || !config.bannedCommitTrailers.every((value) => typeof value === 'string' && value.length > 0 && value === value.trim())) throw new ConfigurationError('bannedCommitTrailers must be an array of non-empty strings with no leading or trailing whitespace');
  if (!Array.isArray(config.exemptBranches) || !config.exemptBranches.every((value) => typeof value === 'string')) throw new ConfigurationError('exemptBranches must be an array of strings');
  if (!Array.isArray(config.excludeGlobs) || !config.excludeGlobs.every((value) => typeof value === 'string')) throw new ConfigurationError('excludeGlobs must be an array of strings');
  if (typeof config.requireProof !== 'boolean') throw new ConfigurationError('requireProof must be true or false');
  if (typeof config.requireAttributableProof !== 'boolean') throw new ConfigurationError('requireAttributableProof must be true or false');
  if (!Array.isArray(config.uiGlobs) || !config.uiGlobs.every((value) => typeof value === 'string')) throw new ConfigurationError('uiGlobs must be an array of strings');
  if (!Array.isArray(config.uiExcludeGlobs) || !config.uiExcludeGlobs.every((value) => typeof value === 'string')) throw new ConfigurationError('uiExcludeGlobs must be an array of strings');
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
  let prefixSource = 'config';
  if (!config.prefix) {
    const fallback = resolveFallbackPrefix(repoName);
    config.prefix = fallback.prefix;
    prefixSource = fallback.source;
  }
  validateConfig(config);
  return {
    config,
    path: filename,
    prefixSource,
    provenance: prefixSource === 'config'
      ? 'from .github/pr-standards.json'
      : prefixSource === 'registry'
        ? 'from repo-prefixes.json'
        : 'derived',
    usedDefaultPrefix: !Object.prototype.hasOwnProperty.call(overrides, 'prefix'),
  };
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

// The commit list caps at 250. A check that cannot see every commit must not
// report a pass, which is how the file list beside this one already behaves.
async function fetchPullCommits(repo, number) {
  const commits = [];
  for (let page = 1; ; page += 1) {
    const pageCommits = await apiRequest(`pulls/${number}/commits?per_page=100&page=${page}`, repo);
    if (!Array.isArray(pageCommits)) throw new ApiError(`GitHub returned an invalid commit list for pull request ${number}`);
    commits.push(...pageCommits);
    if (pageCommits.length < 100) return commits;
  }
}

// Agents append vanity attribution to commit messages. The commits should read
// as the author's own work, so a trailer naming a model or an agent fails the
// PR. This is about the COMMIT trailer only: `Assisted-by:` in the pull request
// body is required by the standard and is a different thing, disclosure rather
// than credit.
const COAUTHOR_LINE_RE = /^\s*co-authored-by:\s*(.*)$/i;
// `Assisted-by:` is the disclosure trailer the standard requires in the pull
// request BODY. A commit that carries the same trailer is not disclosure, it
// is the credit-in-every-commit-message the standard bans, so any occurrence
// here fails regardless of which agent it names.
const ASSISTED_BY_LINE_RE = /^\s*assisted-by:\s*(.*)$/i;
// Anchored to the start of the line: this is an agent's marketing footer
// trailer, not any mention of "generated with X" inside ordinary commit
// prose. The agent name itself is checked against bannedCommitTrailers
// below, so this only recognizes the shape of the line, not a specific
// agent -- otherwise a repo that added Gemini or Codex to its config would
// still pass a "Generated with Gemini" footer because this regex only knew
// about Claude Code.
// The emoji class includes VS16 (️) and ZWJ (‍) because real emoji
// footers are multi-codepoint sequences (a pictograph plus a variation
// selector, or a ZWJ joining several pictographs). `*`, not `?`, so the whole
// sequence is consumed instead of just its first codepoint.
// Captures the remainder of the line so the name check below runs only
// against the disclosed agent, not the whole line -- otherwise a link target
// such as `Generated with Zephyr (https://cursor.example/docs)` fails
// because "cursor" appears in the URL, even though Zephyr is not banned.
const FOOTER_LINE_RE = new RegExp(`^\\s*(?:${EMOJI_RE.source})*\\s*generated (?:with|by)\\b(.*)$`, 'iu');

export function validateCommits(commits, config, truncated = false) {
  const failures = [];
  if (truncated) {
    failures.push(fail(
      'commit list truncated',
      'the API returned fewer commits than the pull request reports',
      'every commit',
      'GitHub caps the list at 250. A pull request that long cannot be reviewed. Split it.',
    ));
  }
  const banned = config.bannedCommitTrailers || [];
  // Word boundaries on both sides. Without them `pi` matches inside "Pia" and
  // `GPT` inside "Gupta", and a human co-author gets their PR failed for having
  // the wrong name.
  // `\b` needs a word/non-word transition, so it never matches beside a name
  // that starts or ends with punctuation: a configured `@cursor` could not fire
  // against the space before it, and the trailer passed silently. Choose the
  // boundary per name. Word char at the edge takes `\b`; anything else takes a
  // "not adjacent to a word char" lookaround, which still blocks it embedding
  // in a longer word (mycursor) but -- unlike requiring literal whitespace --
  // also fires beside ordinary punctuation such as the `[` in a markdown
  // footer link: `[@cursor](url)`. The default list is all alphanumeric, so
  // this only shows up once someone uses the documented config, which is
  // exactly when a quiet failure is hardest to notice.
  const bound = (name) => {
    const quoted = escapeRegex(name);
    const left = /^\w/.test(name) ? '\\b' : '(?<!\\w)';
    const right = /\w$/.test(name) ? '\\b' : '(?!\\w)';
    return `${left}${quoted}${right}`;
  };
  const named = banned.length
    ? new RegExp(`(?:${banned.map(bound).join('|')})`, 'i')
    : null;

  for (const entry of commits) {
    const message = entry?.commit?.message || '';
    const sha = (entry?.sha || '').slice(0, 7);
    for (const line of message.split('\n')) {
      const coAuthor = COAUTHOR_LINE_RE.exec(line);
      const assistedBy = ASSISTED_BY_LINE_RE.exec(line);
      const footer = FOOTER_LINE_RE.exec(line);
      if (coAuthor) {
        // Strip complete <...> segments rather than truncating at the first `<`.
        // Matching only the part before it means everything AFTER the email is
        // discarded too, so `vibecodereview <bot@example.com> Claude` reads as
        // the exempt bot and the Claude behind it is never seen. Removing the
        // segments keeps the reason for doing this at all, which is that a human
        // at an @anthropic.com address must not fail for their email domain.
        const name = coAuthor[1].replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
        // The owner's own review bot records what it changed. That is a real
        // author, not a model taking credit, so it stays exempt -- but only
        // when the name is exactly that bot, not a banned name smuggled in
        // alongside it (e.g. "vibecodereview Claude").
        if (/^vibecodereview$/i.test(name)) continue;
        if (!named || !named.test(name)) continue;
      } else if (assistedBy) {
        // No banned-name check: this trailer only exists to disclose an
        // agent, so its mere presence in a commit is the violation.
      } else if (footer) {
        // Strip URL segments before testing so a link target doesn't decide
        // the outcome: a markdown link's visible text is what was disclosed,
        // the parenthetical or bare URL beside it is not.
        const name = footer[1]
          .replace(/\(https?:\/\/[^)]*\)/gi, ' ')
          .replace(/https?:\/\/\S+/gi, ' ')
          .replace(/[[\]]/g, ' ')
          .trim();
        if (!named || !named.test(name)) continue;
      } else {
        continue;
      }
      failures.push(fail(
        `AI attribution in ${sha}`,
        line.trim(),
        'no model or agent named in a commit trailer',
        `Reword the commit: git rebase -i, or amend if it is the only one. Keep Assisted-by in the PR body instead.`,
      ));
      break;
    }
  }
  return { ok: failures.length === 0, failures };
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
    if (arg === '--branch' || arg === '--title' || arg === '--repo' || arg === '--number' || arg === '--prefix') {
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
  pr-standards precheck --branch X [--title Y] [--prefix P]
  pr-standards pr --repo owner/name --number N
  pr-standards --selfcheck

Add --json to any command for machine-readable output.`;
}

async function runBranch(options) {
  const root = repoRoot();
  const named = repositoryNameWithSource(root);
  const { config, prefixSource } = loadConfig(root, named.name);
  // Say where the prefix came from. A prefix guessed from a directory name is
  // the one most likely to be wrong, so it must not look identical to one read
  // from the repo's own config.
  const provenance = prefixSource === 'config'
    ? 'from .github/pr-standards.json'
    : prefixSource === 'registry'
      ? 'from repo-prefixes.json'
      : `derived from ${named.source}`;
  if (options.branch || options.title || options.repo || options.number || options.prefix) throw new ConfigurationError('branch accepts only one optional branch name');
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
  const { config, prefixSource } = loadConfig(root, named.name);
  // Say where the prefix came from. A prefix guessed from a directory name is
  // the one most likely to be wrong, so it must not look identical to one read
  // from the repo's own config.
  const provenance = prefixSource === 'config'
    ? 'from .github/pr-standards.json'
    : prefixSource === 'registry'
      ? 'from repo-prefixes.json'
      : `derived from ${named.source}`;
  if (!options.branch) throw new ConfigurationError('precheck requires --branch');
  if (options.positional.length > 0 || options.repo || options.number) throw new ConfigurationError('precheck accepts --branch, --prefix and optional --title only');
  // A caller may be judging a branch for a DIFFERENT repo than the one it is
  // standing in. The PreToolUse guard is exactly that case: it runs in the
  // session's working directory while `gh pr create --repo X` targets X. Without
  // this, the branch is checked against the wrong prefix and a conforming
  // cross-repo PR is refused.
  let effective = config;
  let effectiveProvenance = provenance;
  if (options.prefix) {
    if (!isValidPrefix(options.prefix)) {
      throw new ConfigurationError(`--prefix must be 2-4 lowercase letters, got: ${options.prefix}`);
    }
    effective = { ...config, prefix: options.prefix };
    effectiveProvenance = 'from --prefix';
  }
  const branchResult = validateBranchName(options.branch, effective);
  const failures = [...branchResult.failures];
  const passes = branchResult.ok ? [`branch name: ${options.branch}`] : [];
  if (options.title) {
    if (!branchResult.exempt) {
      if (branchResult.issueNumber !== null || branchResult.choreEscape) {
        const titleResult = validateTitle(options.title, effective.prefix, branchResult.issueNumber);
        failures.push(...titleResult.failures);
        if (titleResult.ok) passes.push('PR title');
      } else {
        failures.push(fail('PR title', options.title, 'a valid branch issue number before checking the title', 'Fix the branch name first.'));
      }
    }
  }
  return finish({ mode: 'precheck', prefix: effective.prefix, provenance: effectiveProvenance, failures, warnings: [], passes }, options.json);
}

async function fetchRemoteConfig(repo, repoName, ref) {
  const fallback = resolveFallbackPrefix(repoName);
  try {
    const query = ref ? `?ref=${encodeURIComponent(ref)}` : '';
    const response = await apiRequest(`contents/.github/pr-standards.json${query}`, repo);
    if (response.encoding === 'base64' && typeof response.content === 'string') {
      const content = Buffer.from(response.content, 'base64').toString('utf8');
      // An empty file is a broken config, not an absent one. The local path
      // already errors on it; the remote path used to fall through to defaults,
      // so the same mistake produced different rules depending on the caller.
      if (!content.trim()) {
        throw new ConfigurationError(`${repo} .github/pr-standards.json is empty`);
      }
      const overrides = JSON.parse(content);
      if (!overrides || Array.isArray(overrides) || typeof overrides !== 'object') {
        throw new ConfigurationError(`${repo} .github/pr-standards.json must contain a JSON object`);
      }
      const config = { ...DEFAULT_CONFIG, ...overrides };
      const prefixSource = config.prefix ? 'config' : fallback.source;
      if (!config.prefix) config.prefix = fallback.prefix;
      validateConfig(config);
      const provenance = prefixSource === 'config'
        ? `from ${repo} .github/pr-standards.json${ref ? ` @ ${ref}` : ''}`
        : prefixSource === 'registry'
          ? 'from repo-prefixes.json'
          : `derived; ${repo} has no config prefix`;
      return { config, provenance };
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
  const config = { ...DEFAULT_CONFIG, prefix: fallback.prefix };
  validateConfig(config);
  const provenance = fallback.source === 'registry'
    ? `from repo-prefixes.json; ${repo} has no config`
    : `derived; ${repo} has no config`;
  return { config, provenance };
}

async function runPr(options) {
  if (options.positional.length > 0 || options.branch || options.title || options.prefix) throw new ConfigurationError('pr accepts --repo and --number only');
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
  const loaded = await fetchRemoteConfig(options.repo, repoName, baseRef);
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
  // Files are needed before the body check so proof can be verified against
  // the actual diff. There is no proof override label -- see checkProof.
  const [commits, files] = await Promise.all([
    fetchPullCommits(options.repo, number),
    fetchPullFiles(options.repo, number),
  ]);
  const commitsTruncated = typeof pull.commits === 'number' && commits.length < pull.commits;
  const commitResult = validateCommits(commits, config, commitsTruncated);
  failures.push(...commitResult.failures);
  if (commitResult.ok) passes.push(`${commits.length} commit messages`);
  // GitHub's pull-request files endpoint stops at 3000 entries and gives no
  // signal that it did. Comparing against the count the pull request itself
  // reports is the only way to notice, and a size check that silently measured
  // part of a diff would be worse than one that admits it cannot.
  // A size gate that cannot see the whole diff must not report a pass. Passing
  // on a partial list is the one outcome that is actively wrong: the unseen
  // remainder is exactly where the size-triggering change would be.
  const truncated = typeof pull.changed_files === 'number' && files.length < pull.changed_files;
  if (truncated) {
    failures.push(fail(
      'diff too large to measure',
      `the API returned ${files.length} of ${pull.changed_files} changed files`,
      'a diff small enough to read in full',
      'GitHub caps the file list at 3000. A pull request this size cannot be reviewed or measured. Split it.',
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
  if (!branchResult.exempt) {
    const titleResult = validateTitle(pull.title || '', config.prefix, branchResult.issueNumber);
    failures.push(...titleResult.failures);
    if (titleResult.ok) passes.push('PR title');
    const bodyResult = validateBody(pull.body || '', branchResult.issueNumber, config);
    failures.push(...bodyResult.failures);
    if (bodyResult.ok) passes.push('PR body');
    // Same exemption as title and body: a branch exempt from the `## How I
    // verified` convention (release, refactor, gh-pages, dependabot/*,
    // renovate/*) has no reason to carry a section it was never asked to
    // write, so proof of work rides with the checks it depends on.
    const proofResult = checkProof(pull.body || '', files, config);
    failures.push(...proofResult.failures);
    warnings.push(...proofResult.warnings);
    if (proofResult.failures.length === 0) passes.push('proof of work');
  }
  const sizeResult = checkSize(summary, config);
  failures.push(...sizeResult.failures);
  warnings.push(...sizeResult.warnings);

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
