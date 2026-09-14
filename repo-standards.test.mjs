import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { detectKind, lintReadme } from './repo-standards.mjs';

const LAUNCHER = fileURLToPath(new URL('./repo-standards', import.meta.url));
const PITCH = 'Share a live agent session by URL, read-only or hands-on.';
const CONTRIB = 'https://github.com/pooriaarab/.github/blob/main/CONTRIBUTING.md';
const SPINE = [
  '## Install', '', '```bash', 'npm install x', '```', '', '## Quick start', '', '```bash', 'x run', '```', '',
  '    ok', '', '## Why', '', 'For operators. Replaces scripts. Not a library.', '', '## Usage', '',
  '`x run` starts it.', '', '## How it works', '', 'A script calls Node.', '', '## Contributing', '',
  `See [CONTRIBUTING](${CONTRIB}).`, '', '## License', '', '[MIT](LICENSE)',
].join('\n');
function door({ pitch = PITCH, proof = '' } = {}) {
  return `<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero-dark.png"/>
    <img src="assets/hero-light.png" alt="Two terminals sharing one cursor" width="900"/>
  </picture>
</p>\n\n<p align="center">${pitch}</p>\n
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License MIT"/></a>
</p>\n${proof}`;
}
const SHOT = '\n<p align="center">\n  <img src="assets/shot.png" alt="Command output showing ranked results"/>\n</p>\n';
const CODE = '\n```js\nimport { x } from "x";\nx();\n```\n';
const SWITCH = '\n<p align="center">\n  <a href="README.md"><b>English</b></a> ·\n  <a href="docs/translations/zh.md">中文</a>\n</p>\n';
const TABLE = '\n| Skill | What |\n|---|---|\n| [x](SKILL.md) | Does x |\n';
const READMES = {
  cli: `${door({ proof: SHOT })}\n\n${SPINE}`,
  library: `${door({ proof: CODE })}\n\n${SPINE}`,
  app: `${door({ proof: SHOT })}\n\n${SPINE.replace('## Why', '## Run it locally\n\nPostgres must be up.\n\n## Why')}`,
  collection: `${door({})}\n\n${SPINE.replace('## Why', `## Why\n${TABLE}`)}`,
  infrastructure: `# fleet scripts\n\n${SPINE}`,
};
const ZH = { 'docs/translations/zh.md': '<!-- translated-from: 4d8c7a6 -->\n中文\n' };
const withSwitch = (md, sw = SWITCH) => md.replace(SHOT, `${sw}${SHOT}`);

function tree(kind, extra = {}) {
  const files = {
    'README.md': extra.readme ?? READMES[kind], LICENSE: 'MIT',
    'assets/hero-light.png': '', 'assets/hero-dark.png': '', 'assets/shot.png': '',
  };
  if (kind === 'cli') Object.assign(files, { 'bin/x': '', 'package.json': '{"bin":{"x":"bin/x"}}' });
  if (kind === 'library') files['package.json'] = '{"main":"index.js"}';
  if (kind === 'collection') files['SKILL.md'] = '# x\n';
  if (kind === 'infrastructure') Object.assign(files, { '.github/workflows/ci.yml': 'name: ci\n', 'a.sh': '#!/bin/sh\n', 'b.sh': '#!/bin/sh\n' });
  for (const [key, value] of Object.entries(extra)) { if (key !== 'readme') files[key] = value; }
  return files;
}
function withDir(files, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rs-'));
  try {
    for (const [rel, body] of Object.entries(files)) {
      const abs = path.join(dir, rel);
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, body);
    }
    return fn(dir);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
const lint = (files, opts = {}) => withDir(files, (dir) => lintReadme(path.join(dir, 'README.md'), opts));
const has = (result, rule, level) => result.findings.some((f) => f.rule === rule && (!level || f.level === level));
const errors = (result) => result.findings.filter((f) => f.level === 'error');
const tweak = (kind, fn, extra = {}) => lint(tree(kind, { readme: fn(READMES[kind]), ...extra }));
const run = (args) => spawnSync(process.execPath, [LAUNCHER, ...args], { encoding: 'utf8' });
const pass = (kind, rule) => assert.ok(!has(lint(tree(kind)), rule));

for (const kind of ['cli', 'library', 'app', 'collection', 'infrastructure']) {
  test(`golden ${kind} has zero errors`, () => {
    const result = lint(tree(kind));
    assert.equal(errors(result).length, 0, JSON.stringify(result.findings, null, 2));
    assert.equal(result.kind, kind);
  });
}

test('detectKind reads bin, main, SKILL.md, workflows, else app', () => {
  withDir({ 'package.json': '{"bin":{"x":"bin/x"}}', 'bin/x': '' }, (d) => assert.equal(detectKind(d).kind, 'cli'));
  withDir({ 'package.json': '{"main":"i.js"}' }, (d) => assert.equal(detectKind(d).kind, 'library'));
  withDir({ 'SKILL.md': '#' }, (d) => assert.equal(detectKind(d).kind, 'collection'));
  withDir({ '.github/workflows/c.yml': 'n', 'a.sh': '' }, (d) => assert.equal(detectKind(d).kind, 'infrastructure'));
  withDir({ 'README.md': '#' }, (d) => assert.equal(detectKind(d).kind, 'app'));
});

test('kind-detect-1 warns when signals collide, and skips kind deltas', () => {
  const result = lint(tree('cli', { 'SKILL.md': '# x\n' }));
  assert.ok(has(result, 'kind-detect-1', 'warning'));
  assert.equal(result.kind, 'unknown');
  assert.ok(!has(result, 'kind-1'));
});

function check(name, rule, level, kind, fn, extra) {
  test(name, () => {
    assert.ok(has(tweak(kind, fn, extra), rule, level));
    pass(kind, rule);
  });
}
check('front-door-1 missing title', 'front-door-1', 'error', 'cli', (md) => md.replace(/<p align="center">\s*<picture[\s\S]*?<\/picture>\s*<\/p>/, ''));
test('front-door-1 badges before pitch is out of order', () => {
  const swapped = READMES.cli.replace(`<p align="center">${PITCH}</p>\n\n`, '')
    .replace('alt="License MIT"/></a>\n</p>', `alt="License MIT"/></a>\n</p>\n\n<p align="center">${PITCH}</p>`);
  assert.ok(has(lint(tree('cli', { readme: swapped })), 'front-door-1', 'error'));
});
check('front-door-2 missing pitch', 'front-door-2', 'error', 'cli', (md) => md.replace(`<p align="center">${PITCH}</p>`, ''));
test('front-door-2 multi-sentence pitch fails, one sentence passes', () => {
  assert.ok(has(tweak('cli', (md) => md.replace(PITCH, 'One. Two.')), 'front-door-2', 'error'));
  pass('cli', 'front-door-2');
});
check('front-door-3 long pitch', 'front-door-3', 'error', 'cli', (md) => md.replace(PITCH, `${'x'.repeat(121)}.`));
check('front-door-4 marketing words', 'front-door-4', 'error', 'cli', (md) => md.replace(PITCH, 'A powerful tool for everyone here.'));
test('front-door-5 more than five badges fails, one badge passes', () => {
  const badges = Array.from({ length: 6 }, (_, i) => `<img src="https://img.shields.io/badge/b-${i}-blue" alt="b${i}"/>`).join('');
  assert.ok(has(tweak('cli', (md) => md.replace('alt="License MIT"/></a>', `alt="License MIT"/></a>${badges}`)), 'front-door-5', 'error'));
  pass('cli', 'front-door-5');
});
check('front-door-6 missing alt', 'front-door-6', 'error', 'cli', (md) => md.replace('alt="Command output showing ranked results"', ''));
test('front-door-6 repo-name alt fails, descriptive alt passes', () => {
  assert.ok(has(tweak('cli', (md) => md.replace('alt="Command output showing ranked results"', 'alt="cli"'), { 'package.json': '{"name":"cli","bin":{"x":"bin/x"}}' }), 'front-door-6', 'error'));
  pass('cli', 'front-door-6');
});
check('front-door-7 user-attachments', 'front-door-7', 'error', 'cli', (md) => md.replace('assets/shot.png', 'https://github.com/user-attachments/assets/abc'));
test('front-door-7 remote non-badge image fails, relative passes', () => {
  assert.ok(has(tweak('cli', (md) => md.replace('assets/shot.png', 'https://example.com/shot.png')), 'front-door-7', 'error'));
  pass('cli', 'front-door-7');
});
test('front-door-8 a single-theme hero warns, a picture pair passes', () => {
  const md = READMES.cli.replace(/<picture>[\s\S]*?<\/picture>/, '<img src="assets/hero-light.png" alt="Two terminals sharing one cursor" width="900"/>');
  assert.ok(has(lint(tree('cli', { readme: md })), 'front-door-8', 'warning'));
  pass('cli', 'front-door-8');
});
check('front-door-9 banner plus H1', 'front-door-9', 'error', 'cli', (md) => `# named\n\n${md}`);
// A GitHub Actions badge URL ends in /badge.svg, not /badge/. Treating it as a
// content image made the whole badge row classify as proof, which then read the
// caption under the real proof as a second pitch. One miss, three wrong findings.
test('an Actions badge is a badge, and a caption under proof is not a pitch', () => {
  const md = READMES.cli.replace(
    '<p align="center">\n  <a href="LICENSE">',
    '<p align="center">\n  <a href="x"><img src="https://github.com/o/r/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>\n  <a href="LICENSE">',
  ).replace('## Install', '<p align="center"><em>What the run prints.</em></p>\n\n## Install');
  const result = lint(tree('cli', { readme: md }));
  assert.ok(!has(result, 'front-door-7'), 'an Actions badge is not a hot-linked image');
  assert.ok(!has(result, 'front-door-1'), 'a caption is not a second pitch');
});
test('infrastructure skips banner, pitch-marketing, and badge-cap rules', () => {
  const result = lint(tree('infrastructure'));
  assert.ok(!has(result, 'front-door-2'));
  assert.ok(!has(result, 'front-door-4'));
  assert.ok(!has(result, 'front-door-5'));
  assert.equal(errors(result).length, 0);
});
test('--help prints usage, --json prints only JSON, and findings use the documented line shape', () => {
  const help = run(['--help']);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /Usage:/);
  assert.match(help.stdout, /readme/);
  withDir(tree('cli'), (dir) => {
    const json = run(['readme', '--json', dir]);
    assert.equal(json.status, 0);
    const parsed = JSON.parse(json.stdout);
    assert.equal(parsed.kind, 'cli');
    assert.ok(Array.isArray(parsed.findings));
    assert.equal(json.stdout.trim().split('\n').length, 1);
    assert.equal(run(['readme', dir]).status, 0);
  });
  withDir(tree('cli', { readme: READMES.cli.replace(PITCH, `${'x'.repeat(121)}.`) }), (dir) => {
    const out = run(['readme', path.join(dir, 'README.md')]);
    assert.equal(out.status, 1);
    assert.match(out.stdout, /^repo-standards: .+ \[front-door-3\] error {2}The pitch runs \d+ characters\. Cut it to 120\.$/m);
    const parsed = JSON.parse(run(['readme', '--json', dir]).stdout);
    assert.ok(parsed.findings.some((f) => f.rule === 'front-door-3' && f.level === 'error' && f.line >= 1));
  });
});
test('unknown options and missing paths are configuration errors', () => {
  assert.equal(run(['readme', '--nope', '.']).status, 2);
  assert.equal(run(['readme']).status, 2);
  assert.equal(run(['readme', '/tmp/does-not-exist-rs']).status, 2);
});
