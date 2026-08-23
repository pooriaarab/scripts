#!/usr/bin/env node
/**
 * Generate a ChatGPT App Submission import file (schema v1) from a small config.
 * The portal (platform.openai.com) accepts this as the "Codex-generated" upload
 * that fills the submission form.
 *
 *   node gen.mjs config.json > chatgpt-app-submission.json
 *
 * The hard part the portal demands: EVERY tool needs annotations
 * (readOnlyHint, openWorldHint, destructiveHint) AND a justification for each.
 * Feed the tool list from your MCP registry so these come from the source of
 * truth, not by hand. Config shape:
 *
 * {
 *   "app_info": { "display_name": "...", "subtitle": "<=30 chars",
 *                 "description": "<=4000", "category": "PRODUCTIVITY" },
 *   "open_world": true,                 // default openWorldHint for every tool
 *   "tools": [ { "name": "posts_list", "readOnly": true, "destructive": false }, ... ],
 *   "test_cases": [ { "description": "...", "user_prompt": "...",
 *                     "tools_triggered": "posts_create, posts_schedule" }, ... ],  // >=5
 *   "negative_test_cases": [ { "description": "...", "user_prompt": "..." }, ... ]  // >=3
 * }
 *
 * category enum: BUSINESS, COLLABORATION, DESIGN, DEVELOPER_TOOLS, EDUCATION,
 * ENTERTAINMENT, FINANCE, FOOD, LIFESTYLE, NEWS, PRODUCTIVITY, SHOPPING, TRAVEL.
 */
import { readFileSync } from "node:fs";

const SCHEMA = "https://developers.openai.com/plugins/schemas/chatgpt-app-submission.v1.json";

const configPath = process.argv[2];
if (!configPath) {
  console.error("usage: node gen.mjs config.json > chatgpt-app-submission.json");
  process.exit(1);
}
const cfg = JSON.parse(readFileSync(configPath, "utf8"));

const openWorldDefault = cfg.open_world !== false; // default true

function justify(readOnly, destructive, openWorld) {
  return {
    read_only_justification: readOnly
      ? "Only reads the user's own data; performs no writes or side effects."
      : "Creates, updates, or acts on the user's own data; not read-only.",
    open_world_justification: openWorld
      ? "Interacts with external systems / third-party platforms."
      : "Operates only on the app's own closed data set.",
    destructive_justification: destructive
      ? "Permanently removes or disconnects data; irreversible, so flagged destructive."
      : "Does not delete data; changes are additive or reversible.",
  };
}

const tools = {};
for (const t of cfg.tools ?? []) {
  const readOnly = t.readOnly === true;
  const destructive = t.destructive === true;
  const openWorld = t.openWorld ?? openWorldDefault;
  tools[t.name] = {
    annotations: { readOnlyHint: readOnly, openWorldHint: openWorld, destructiveHint: destructive },
    justifications: justify(readOnly, destructive, openWorld),
  };
}

const out = {
  $schema: SCHEMA,
  schema_version: 1,
  ...(cfg.app_info ? { app_info: cfg.app_info } : {}),
  tools,
  ...(cfg.test_cases ? { test_cases: cfg.test_cases } : {}),
  ...(cfg.negative_test_cases ? { negative_test_cases: cfg.negative_test_cases } : {}),
};

// Cheap guardrails against the portal's minItems rules.
if ((out.test_cases?.length ?? 0) < 5) console.error("WARN: need >=5 test_cases");
if ((out.negative_test_cases?.length ?? 0) < 3) console.error("WARN: need >=3 negative_test_cases");

process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
