#!/usr/bin/env node
// Build an OpenAI plugin submission ZIP for one site.
//
//   node build.mjs sites/marriagelicense.json [outdir]
//
// Emits <outdir>/<slug>.zip containing:
//   <slug>-plugin/.mcp.json                      remote MCP server, "type": "http"
//   <slug>-plugin/.codex-plugin/plugin.json      manifest + interface + extensions.com.openai
//   <slug>-plugin/assets/logo.svg                square icon (SVG allowed, viewBox >= 48)
//   <slug>-plugin/assets/og.png                  screenshot (any landscape raster)
//
// The manifest shape mirrors the complete Codex example in
// https://developers.openai.com/plugins/deploy/submission — field limits that
// caused live validator findings are enforced here instead.

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const [configPath, outdir = '.'] = process.argv.slice(2);
if (!configPath) {
  console.error('usage: node build.mjs sites/<slug>.json [outdir]');
  process.exit(1);
}
const cfg = JSON.parse(readFileSync(configPath, 'utf8'));

const REQUIRED = ['slug', 'domain', 'display_name', 'subtitle', 'long_description', 'capabilities', 'prompts', 'logo', 'screenshot'];
for (const k of REQUIRED) {
  if (!cfg[k]) { console.error(`missing required field: ${k}`); process.exit(1); }
}
if (cfg.subtitle.length > 30) { console.error(`subtitle ${cfg.subtitle.length} chars > 30`); process.exit(1); }
if (cfg.display_name.length > 30) { console.error(`display_name ${cfg.display_name.length} chars > 30`); process.exit(1); }
if (/\bfree\b|\$|\bpricing\b|\bsubscriptions?\b|\btrial\b/i.test(cfg.long_description)) {
  console.error('long_description contains pricing words — the validator flags them');
  process.exit(1);
}
if (!cfg.display_name.includes('.')) {
  console.error('display_name should carry the domain brand (e.g. Example.fyi) — bare nouns fail "name too generic"');
  process.exit(1);
}

const root = mkdtempSync(join(tmpdir(), `${cfg.slug}-`));
const plugin = join(root, `${cfg.slug}-plugin`);
mkdirSync(join(plugin, '.codex-plugin'), { recursive: true });
mkdirSync(join(plugin, 'assets'), { recursive: true });

writeFileSync(join(plugin, '.mcp.json'), JSON.stringify({
  mcpServers: { [cfg.slug]: { type: 'http', url: `https://${cfg.domain}/mcp` } },
}, null, 2));

const manifest = {
  name: cfg.slug,
  version: '1.0.0',
  description: cfg.subtitle,
  author: { name: 'Beeloud', url: 'https://beeloud.xyz', email: `support@${cfg.domain}` },
  homepage: `https://${cfg.domain}`,
  mcpServers: './.mcp.json',
  interface: {
    displayName: cfg.display_name,
    shortDescription: cfg.subtitle,
    longDescription: cfg.long_description,
    developerName: 'Beeloud',
    category: cfg.category || 'Productivity',
    capabilities: cfg.capabilities,
    websiteURL: `https://${cfg.domain}`,
    supportURL: `https://${cfg.domain}/contact`,
    privacyPolicyURL: `https://${cfg.domain}/privacy`,
    termsOfServiceURL: `https://${cfg.domain}/terms`,
    defaultPrompt: cfg.prompts.slice(0, 3),
    composerIcon: './assets/logo.svg',
    logo: './assets/logo.svg',
    screenshots: ['./assets/og.png'],
  },
  keywords: [cfg.slug.split('-')[0], 'directory', 'search', 'mcp'],
  extensions: {
    'com.openai': {
      review: {
        test_cases: {
          positive: [
            { description: 'Search by place', prompt: `${cfg.prompts[0]}.`, tools_triggered: 'search_listings', expected_behavior: 'Return matching listings with names, places and source links.' },
            { description: 'Open a listing', prompt: cfg.prompts[1], tools_triggered: 'search_listings, get_listing', expected_behavior: 'Find a matching listing and return its full details with a source link.' },
            { description: 'Browse coverage', prompt: `${cfg.prompts[2]}.`, tools_triggered: 'list_places', expected_behavior: 'List the places the directory covers.' },
            { description: 'Directory stats', prompt: 'How many listings does the directory have?', tools_triggered: 'get_stats', expected_behavior: "Return the directory's listing counts and coverage statistics." },
            { description: 'No matches', prompt: 'Find listings in a place the directory does not cover.', tools_triggered: 'search_listings', expected_behavior: 'Report that no matching listings were found.' },
          ],
          negative: [
            { description: 'Unsupported payment', prompt: 'Pay for a premium listing.' },
            { description: 'Unsupported deletion', prompt: 'Delete a listing from the directory.' },
            { description: 'Unsupported write', prompt: 'Add my business to the directory.' },
          ],
        },
        demo_recording_url: `https://${cfg.domain}/developers`,
        commerce: false,
        commerce_description: 'This plugin does not sell products or process payments.',
      },
      publication: {
        release_notes: 'Initial release: remote MCP server with directory search, listing detail, places, categories, stats and sources tools.',
      },
    },
  },
};
writeFileSync(join(plugin, '.codex-plugin', 'plugin.json'), JSON.stringify(manifest, null, 2));

cpSync(resolve(cfg.logo), join(plugin, 'assets', 'logo.svg'));
cpSync(resolve(cfg.screenshot), join(plugin, 'assets', 'og.png'));

const out = join(resolve(outdir), `${cfg.slug}.zip`);
rmSync(out, { force: true });
execFileSync('zip', ['-qr', out, `${cfg.slug}-plugin`], { cwd: root });
console.log(out);
rmSync(root, { recursive: true, force: true });
