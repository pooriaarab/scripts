import fs from 'node:fs';
import path from 'node:path';

// Shape only. A precise pitch of the wrong product still passes, which is why
// a person still has to read the README. repo-standards.md is the spec.

export const KINDS = ['cli', 'library', 'app', 'collection', 'infrastructure'];
export const REQUIRED_SECTIONS = [
  'Install', 'Quick start', 'Why', 'Usage', 'How it works', 'Contributing', 'License',
];
export const BANNED_PITCH = [
  'powerful', 'seamless', 'robust', 'blazing', 'effortless', 'comprehensive', 'revolutionary',
];
const ORDER = ['title', 'pitch', 'badges', 'switcher', 'proof'];
const EMOJI_RE = /[\p{Extended_Pictographic}\p{Regional_Indicator}\uFE0F\u200D]/u;
const BANNED_RE = new RegExp(`\\b(${BANNED_PITCH.join('|')})\\b`, 'i');

export class ConfigurationError extends Error {
  constructor(message) { super(message); this.name = 'ConfigurationError'; }
}

const add = (out, rule, level, line, message) => { out.push({ rule, level, line, message }); };
const norm = (text) => String(text).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const strip = (text) => String(text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const attr = (tag, name) => (new RegExp(`${name}\\s*=\\s*"([^"]*)"`, 'i').exec(tag)
  || new RegExp(`${name}\\s*=\\s*'([^']*)'`, 'i').exec(tag) || [])[1] || '';
const sentences = (text) => strip(text).split(/[.!?]+(?:\s|$)/).map((p) => p.trim()).filter(Boolean).length;
const readJson = (file) => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };
const isRemote = (href) => /^(https?:)?\/\//i.test(href) || /^(mailto|tel):/i.test(href);
const isBadge = (src) => /shields\.io|\/badge\/|badge\.svg|badgen\.net|forthebadge/i.test(src);
const lineAt = (text, index) => String(text).slice(0, index).split('\n').length;
const exists = (p) => fs.existsSync(p);

function maskFences(text) {
  let fence = false;
  return String(text).replace(/\r\n/g, '\n').split('\n').map((line) => {
    if (/^\s*(```|~~~)/.test(line)) { fence = !fence; return line; }
    return fence ? '' : line;
  }).join('\n');
}

export function detectKind(dir) {
  const names = fs.readdirSync(dir);
  const pkg = names.includes('package.json') ? readJson(path.join(dir, 'package.json')) : null;
  const binDir = names.includes('bin');
  const hits = [];
  if (pkg?.bin || binDir) hits.push('cli');
  if (pkg && (pkg.main || pkg.exports) && !pkg.bin && !binDir) hits.push('library');
  if (names.includes('SKILL.md') || ['skills', 'prompts'].some((n) => names.includes(n)
    && fs.statSync(path.join(dir, n)).isDirectory())) hits.push('collection');
  const infra = exists(path.join(dir, '.github', 'workflows'))
    && names.some((n) => n.endsWith('.sh')) && !(pkg && (pkg.main || pkg.exports || pkg.bin));
  if (infra) hits.push('infrastructure');
  if (hits.length === 1) return { kind: hits[0], ambiguous: false, hits };
  if (hits.length > 1) return { kind: 'unknown', ambiguous: true, hits };
  return { kind: 'app', ambiguous: false, hits };
}

export function resolveReadme(target) {
  const abs = path.resolve(target);
  if (!exists(abs)) throw new ConfigurationError(`not found: ${target}`);
  const stat = fs.statSync(abs);
  if (stat.isFile()) return abs;
  if (!stat.isDirectory()) throw new ConfigurationError(`not a readable path: ${target}`);
  for (const name of ['README.md', 'readme.md', 'Readme.md']) {
    const candidate = path.join(abs, name);
    if (exists(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  throw new ConfigurationError(`no README in ${target}`);
}

function headings(text) {
  const out = [];
  let fence = false;
  const lines = String(text).replace(/\r\n/g, '\n').split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    if (/^\s*(```|~~~)/.test(lines[i])) { fence = !fence; continue; }
    if (fence) continue;
    const m = /^(#{1,6})\s+(.+?)\s*$/.exec(lines[i]);
    if (m) out.push({ level: m[1].length, text: m[2].trim(), line: i + 1 });
  }
  return out;
}

function blocks(text) {
  const lines = String(text).replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let cur = [];
  let start = 1;
  const flush = (end) => {
    if (!cur.length) return;
    out.push({ text: cur.join('\n'), line: start });
    cur = [];
    start = end + 1;
  };
  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i].trim() === '') flush(i + 1);
    else { if (!cur.length) start = i + 1; cur.push(lines[i]); }
  }
  flush(lines.length);
  return out;
}

function classify(block, state) {
  const text = block.text.trim();
  if (/^#\s+/.test(text) && !text.startsWith('##')) return 'h1';
  if (/docs\/translations\//.test(text) || /<b>English<\/b>|\*\*English\*\*/i.test(text)) return 'switcher';
  if (/^\s*(```|~~~)/.test(text) || /<pre[\s>]/i.test(text)) return 'proof';
  const srcs = [...text.matchAll(/<img\b([^>]*)>/gi)].map((m) => attr(m[1], 'src'))
    .concat([...text.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/g)].map((m) => m[1]))
    .concat([...text.matchAll(/\bsrcset\s*=\s*"([^"]+)"/gi)].map((m) => m[1].split(/\s+/)[0]))
    .filter(Boolean);
  if (srcs.length && srcs.every(isBadge)) return 'badges';
  if (srcs.length || /<picture/i.test(text)) return state.pitch ? 'proof' : 'banner';
  return strip(text) && !state.pitch ? 'pitch' : 'other';
}

function collectImages(text) {
  const images = [];
  for (const m of text.matchAll(/<img\b([^>]*)>/gi)) {
    images.push({ src: attr(m[1], 'src'), alt: attr(m[1], 'alt'), hasAlt: /\balt\s*=/i.test(m[1]), line: lineAt(text, m.index) });
  }
  for (const m of text.matchAll(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    images.push({ src: m[2], alt: m[1], hasAlt: true, line: lineAt(text, m.index) });
  }
  for (const m of text.matchAll(/\bsrcset\s*=\s*"([^"]+)"/gi)) {
    images.push({ src: m[1].split(/\s+/)[0], alt: '', hasAlt: true, line: lineAt(text, m.index), srcset: true });
  }
  return images;
}

function collectHrefs(text) {
  const hrefs = [];
  for (const m of text.matchAll(/(?<!!)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    hrefs.push({ href: m[2], text: m[1], line: lineAt(text, m.index) });
  }
  for (const m of text.matchAll(/\bhref\s*=\s*"([^"]+)"/gi)) hrefs.push({ href: m[1], text: '', line: lineAt(text, m.index) });
  return hrefs;
}

function bashFences(text) {
  const lines = String(text).replace(/\r\n/g, '\n').split('\n');
  const fences = [];
  let fence = null;
  let body = [];
  for (let i = 0; i < lines.length; i += 1) {
    const opener = /^\s*(```|~~~)\s*(\S*)/.exec(lines[i]);
    if (fence) {
      if (opener && !opener[2]) { fences.push({ lang: fence.lang, line: fence.line, body: body.join('\n') }); fence = null; body = []; }
      else body.push(lines[i]);
      continue;
    }
    if (opener && opener[2]) fence = { lang: opener[2].toLowerCase(), line: i + 1 };
  }
  return fences;
}

export function lintReadme(readmePath, options = {}) {
  const findings = [];
  const readme = path.resolve(readmePath);
  const dir = path.dirname(readme);
  const detected = detectKind(dir);
  const forced = options.kind || null;
  if (forced && !KINDS.includes(forced)) throw new ConfigurationError(`--kind must be one of ${KINDS.join('|')}`);
  const kind = forced || detected.kind;
  const infra = kind === 'infrastructure';
  const sharedOnly = !forced && detected.ambiguous;
  if (sharedOnly) {
    add(findings, 'kind-detect-1', 'warning', 1,
      `Kind is ambiguous (${detected.hits.join(', ')}). Checking shared sections only.`);
  }
  const text = fs.readFileSync(readme, 'utf8').replace(/\r\n/g, '\n');
  const h2 = headings(text).filter((h) => h.level === 2);
  const firstH2 = h2[0];
  const front = firstH2 ? text.split('\n').slice(0, firstH2.line - 1).join('\n') : text;
  const visible = maskFences(text);
  const names = new Set([path.basename(dir).toLowerCase()]);
  const pkg = readJson(path.join(dir, 'package.json'));
  if (pkg?.name) names.add(String(pkg.name).toLowerCase());
  const state = { h1: false, banner: false };
  const roles = [];
  for (const block of blocks(front)) {
    const role = classify(block, state);
    if (role === 'h1') {
      state.h1 = true;
      names.add(block.text.replace(/^#\s+/, '').trim().toLowerCase());
      roles.push({ role: 'title', line: block.line, block });
    } else if (role === 'banner') {
      state.banner = true;
      roles.push({ role: 'title', line: block.line, block });
    } else if (role === 'pitch') {
      state.pitch = true;
      roles.push({ role, line: block.line, block });
    } else if (role !== 'other') roles.push({ role, line: block.line, block });
  }
  const hasRole = (role) => roles.some((r) => r.role === role);
  const pitchBlock = roles.find((r) => r.role === 'pitch');
  const applyKind = !sharedOnly && kind !== 'unknown';

  if (!infra) {
    if (state.h1 && state.banner) add(findings, 'front-door-9', 'error', 1, 'A banner and an H1 both name the repo. Use one.');
    if (!state.h1 && !state.banner) add(findings, 'front-door-1', 'error', 1, 'The front door has no banner and no H1.');
    let last = -1;
    for (const item of roles) {
      const rank = ORDER.indexOf(item.role);
      if (rank === -1) continue;
      if (rank < last) {
        add(findings, 'front-door-1', 'error', item.line,
          `Front door order is banner, pitch, badges, language switcher, proof. Found ${item.role} out of order.`);
        break;
      }
      last = rank;
    }
    if (!pitchBlock) add(findings, 'front-door-2', 'error', 1, 'The front door has no pitch. Write one sentence under the title.');
    else {
      const pitch = strip(pitchBlock.block.text);
      const count = sentences(pitchBlock.block.text);
      if (count !== 1) add(findings, 'front-door-2', 'error', pitchBlock.line, `The pitch is ${count} sentences. Keep it to one.`);
      if (pitch.length > 120) add(findings, 'front-door-3', 'error', pitchBlock.line, `The pitch runs ${pitch.length} characters. Cut it to 120.`);
      if (BANNED_RE.test(pitch)) add(findings, 'front-door-4', 'error', pitchBlock.line, 'The pitch uses a marketing word the standard bans.');
    }
    const badgeCount = collectImages(front).filter((img) => isBadge(img.src)).length;
    if (badgeCount > 5) add(findings, 'front-door-5', 'error', 1, `The front door has ${badgeCount} badges. The cap is five.`);
    if (state.banner && !/<picture[\s\S]*prefers-color-scheme/i.test(front)) {
      add(findings, 'front-door-8', 'warning', 1, 'Serve the hero in both colour schemes, or it disappears for half the readers.');
    }
  }

  const images = collectImages(visible);
  for (const image of images) {
    if (!image.src) continue;
    if (!image.srcset) {
      if (!image.hasAlt || !String(image.alt).trim()) add(findings, 'front-door-6', 'error', image.line, 'Every image needs alt text that describes the image.');
      else if (names.has(image.alt.trim().toLowerCase())) add(findings, 'front-door-6', 'error', image.line, 'Alt text describes the image, not the repo name.');
    }
    if (/github\.com\/user-attachments\//i.test(image.src)) {
      add(findings, 'front-door-7', 'error', image.line, 'Image paths must be relative. A GitHub user-attachments URL is not a git object.');
    } else if (isRemote(image.src) && !isBadge(image.src)) {
      add(findings, 'front-door-7', 'error', image.line, 'Image paths must be relative, not hot-linked.');
    }
  }


  return { path: readme, kind: sharedOnly ? 'unknown' : kind, findings };
}

function usage() {
  return `Usage:
  repo-standards readme <path>
  repo-standards --help

<path> is a README file or a directory that contains one.
Add --json for machine-readable output.
--kind <${KINDS.join('|')}> forces the repo kind.`;
}

function parseArgs(argv) {
  const json = argv.includes('--json');
  const filtered = argv.filter((a) => a !== '--json');
  if (filtered.includes('--help') || filtered.includes('-h') || filtered.length === 0) return { help: true, json };
  const mode = filtered.shift();
  if (mode !== 'readme') throw new ConfigurationError('usage: repo-standards readme <path>');
  let kind = null;
  const positional = [];
  for (let i = 0; i < filtered.length; i += 1) {
    const arg = filtered[i];
    if (arg === '--kind') {
      const value = filtered[i + 1];
      if (!value || value.startsWith('--')) throw new ConfigurationError('--kind requires a value');
      if (!KINDS.includes(value)) throw new ConfigurationError(`--kind must be one of ${KINDS.join('|')}`);
      kind = value;
      i += 1;
    } else if (arg === '--help' || arg === '-h') return { help: true, json };
    else if (arg.startsWith('--')) throw new ConfigurationError(`unknown option: ${arg}`);
    else positional.push(arg);
  }
  if (positional.length !== 1) throw new ConfigurationError('readme requires a path');
  return { mode: 'readme', json, kind, path: positional[0] };
}

export async function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) { process.stdout.write(`${usage()}\n`); return 0; }
    const result = lintReadme(resolveReadme(options.path), { kind: options.kind });
    const rel = path.relative(process.cwd(), result.path) || path.basename(result.path);
    const findings = result.findings.map(({ rule, level, line, message }) => ({ rule, level, line, message }));
    if (options.json) process.stdout.write(`${JSON.stringify({ path: rel, kind: result.kind, findings })}\n`);
    else for (const item of findings) process.stdout.write(`repo-standards: ${rel}:${item.line} [${item.rule}] ${item.level}  ${item.message}\n`);
    return findings.some((item) => item.level === 'error') ? 1 : 0;
  } catch (error) {
    const json = options?.json || argv.includes('--json');
    const message = error.message || String(error);
    if (json) process.stdout.write(`${JSON.stringify({ path: null, kind: null, findings: [{ rule: 'configuration', level: 'error', line: 1, message }] })}\n`);
    else process.stderr.write(`${message}\n`);
    return error instanceof ConfigurationError ? 2 : 1;
  }
}
