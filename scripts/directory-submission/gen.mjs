#!/usr/bin/env node
/**
 * Generate directory-submission artifacts for one live site.
 *
 *   node gen.mjs site.json --out ./out
 *
 * site.json: { name, tagline, short, long, url, repo, mcp_url,
 *   registry_name, contact_email, pricing, category_web, category_mcp,
 *   tags[], tools[{name, description}], repository_id? }
 *
 * repository_id (numeric GitHub repo id) is optional but recommended: the
 * registry cross-checks the repository, and an explicit id avoids ambiguity.
 *
 * Writes packet.md, server.json, submissions.csv, mcp-so-issue.md,
 * awesome-remote-entry.md into --out. Fails closed: every required field
 * must be present and non-empty, and short/long/tagline length caps are
 * enforced, so a packet never ships a placeholder or an over-long field.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIRS = JSON.parse(readFileSync(join(HERE, "directories.json"), "utf8"));

const args = process.argv.slice(2);
const configPath = args[0];
const outFlag = args.indexOf("--out");
const outDir = outFlag === -1 ? null : args[outFlag + 1];
if (!configPath || !outDir) {
  console.error("usage: node gen.mjs site.json --out ./out");
  process.exit(1);
}
const site = JSON.parse(readFileSync(configPath, "utf8"));

const required = ["name", "tagline", "short", "long", "url", "repo", "mcp_url",
  "registry_name", "contact_email", "pricing", "category_web", "category_mcp", "tags", "tools"];
for (const k of required) {
  const v = site[k];
  const empty = v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0);
  if (empty) {
    console.error(`gen.mjs: site.json is missing required field "${k}" — refusing to emit a packet with placeholders.`);
    process.exit(1);
  }
}
const caps = [["tagline", 60], ["short", 260], ["long", 500]];
for (const [k, max] of caps) {
  if (site[k].length > max) {
    console.error(`gen.mjs: site.json "${k}" is ${site[k].length} chars, cap is ${max}. Shorten it.`);
    process.exit(1);
  }
}
if (site.registry_name.length > 100 || !/^io\.github\.[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(site.registry_name)) {
  console.error("gen.mjs: registry_name must look like io.github.<user>/<repo>.");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
const write = (name, content) => writeFileSync(join(outDir, name), content);

const toolLines = site.tools.map((t) => `- \`${t.name}\`: ${t.description}`).join("\n");
const toolNames = site.tools.map((t) => t.name).join(", ");
const tags = site.tags.join(", ");

// packet.md — every field a directory form asks for.
write("packet.md", `# Submission packet — ${site.name}

Source of truth for directory forms. Copy-paste per directory; do not reword per
directory (listings that disagree with each other read as spam).

- **Name:** ${site.name}
- **Tagline:** ${site.tagline}
- **Short description (${site.short.length}/260):** ${site.short}
- **Long description (${site.long.length}/500):** ${site.long}
- **URL:** ${site.url}
- **Repo:** ${site.repo}
- **Category (web):** ${site.category_web}
- **Category (MCP):** ${site.category_mcp}
- **Tags:** ${tags}
- **Pricing:** ${site.pricing}
- **Contact:** ${site.contact_email}

## MCP endpoint

- **Endpoint:** ${site.mcp_url} (Streamable HTTP, no auth)
- **Registry name:** ${site.registry_name}
- **Tools (${site.tools.length}):** ${toolNames}

${toolLines}

## Client config (paste into MCP client configs / directory forms)

\`\`\`json
{
  "mcpServers": {
    "${site.registry_name.split("/")[1]}": {
      "type": "streamable-http",
      "url": "${site.mcp_url}"
    }
  }
}
\`\`\`
`);

// server.json — official MCP registry manifest, remote-only.
const mcpDesc = site.tagline.length <= 100 ? site.tagline : site.tagline.slice(0, 97) + "...";
const repoId = site.repo.replace(/^https:\/\/github\.com\//, "");
write("server.json", JSON.stringify({
  $schema: "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  name: site.registry_name,
  description: mcpDesc,
  version: "1.0.0",
  repository: { url: site.repo, source: "github", ...(site.repository_id ? { id: String(site.repository_id) } : {}) },
  remotes: [{ type: "streamable-http", url: site.mcp_url }],
}, null, 2) + "\n");

// submissions.csv — tracking sheet, one row per directory.
const csvCell = (v) => `"${String(v).replace(/"/g, '""')}"`;
const rows = [["directory", "tier", "url", "submit", "dr", "link", "gate", "date_submitted", "status"]];
const tiers = [
  ["web_tier1_launch", "web-tier1-launch"], ["web_tier1_startup", "web-tier1-startup"],
  ["web_tier1_saas", "web-tier1-saas"], ["web_tier1_review", "web-tier1-review"],
  ["web_ai_geo", "web-ai-geo"], ["web_longtail", "web-longtail"],
];
for (const [key, tier] of tiers) {
  for (const d of DIRS[key]) rows.push([d.name, tier, d.url, d.submit, d.dr, d.link, d.gate, "", "todo"]);
}
for (const d of DIRS.mcp) rows.push([d.name, "mcp", d.url, d.submit, "", "", d.gate, "", "todo"]);
write("submissions.csv", rows.map((r) => r.map(csvCell).join(",")).join("\n") + "\n");

// mcp-so-issue.md — file with: gh issue create -R chatmcp/mcp-directory -t ... -F mcp-so-issue.md
write("mcp-so-issue.md", `# ${site.name} MCP server

## Server name

${site.name}

## Description

${site.long}

## Repository

${site.repo}

## Endpoint

${site.mcp_url} (Streamable HTTP, no authentication required)

## Tools

${toolLines}

## Client config

\`\`\`json
{
  "mcpServers": {
    "${site.registry_name.split("/")[1]}": {
      "type": "streamable-http",
      "url": "${site.mcp_url}"
    }
  }
}
\`\`\`
`);

// awesome-remote-entry.md — insert under "### ${site.category_mcp}" in the README.
write("awesome-remote-entry.md", `#### [${site.name}](${site.url})

- **Offers:** ${site.short} MCP tools: ${toolNames}.
- **Access:** No authentication required. Use the server URL directly: \`${site.mcp_url}\`
`);

console.log(`wrote 5 files to ${outDir}`);
