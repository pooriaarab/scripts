# chatgpt-app-submission

Generate the `chatgpt-app-submission.json` the ChatGPT App directory portal wants
(the "Codex-generated" upload that fills the submission form). Learned by
shipping Content Rabbit into the directory.

## Run

```sh
node gen.mjs config.json > chatgpt-app-submission.json
```

See `gen.mjs` header for the config shape. Feed the `tools` list from your MCP
registry so annotations come from the source of truth. If your registry already
has readOnly/destructive annotations, script the config out of it (Content
Rabbit did this directly: `bun run scripts/gen-chatgpt-app-submission.mjs`).

## The canonical schema (fetch it, don't guess)

`https://developers.openai.com/plugins/schemas/chatgpt-app-submission.v1.json`
(redirects to `/plugins/schemas/...`). Required top-level: `$schema` (that exact
const), `schema_version: 1`, `tools`. Optional: `app_info`, `test_cases` (**≥5**),
`negative_test_cases` (**≥3**).

- **`tools`** — an object keyed by tool name. EACH tool requires `annotations`
  {`readOnlyHint`, `openWorldHint`, `destructiveHint` — all booleans} AND
  `justifications` {`read_only_justification`, `open_world_justification`,
  `destructive_justification` — all non-empty strings}. This is the tedious part;
  generate it.
- **`app_info`** — `display_name`, `subtitle` (≤30 chars), `description` (≤4000),
  `category` (enum: BUSINESS, COLLABORATION, DESIGN, DEVELOPER_TOOLS, EDUCATION,
  ENTERTAINMENT, FINANCE, FOOD, LIFESTYLE, NEWS, PRODUCTIVITY, SHOPPING, TRAVEL).
- **`test_cases`** — ≥5 of {`description`, `user_prompt`, `tools_triggered`}.
- **`negative_test_cases`** — ≥3 of {`description`, `user_prompt`}.

## Process (what actually happens)

1. **Connect in ChatGPT developer mode first** (Settings → Developer mode →
   Plugins → + → Server URL = your hosted MCP URL, OAuth). This is a PRIVATE
   connection and proves the OAuth works — NOT the public directory.
2. **Start the submission** at platform.openai.com → Create plugin → With MCP →
   Universal URL. The portal creates a NEW app id (different from the dev-mode
   one) — read it from the edit URL `/plugins/edit/<app_id>/<version_id>`.
3. **Upload** the generated `chatgpt-app-submission.json` — the portal rejects
   anything without the exact `$schema` const.
4. **Domain challenge**: serve the portal's token as plain text at
   `/.well-known/openai-apps-challenge` (an env-driven route is cleanest).
5. **Verified identity** on the OpenAI org is a separate publishing gate (dev-mode
   connect does NOT satisfy it).
6. Run **Scan Tools**, add a **logo** (PNG, 256×256, ≤10KB — palette-quantize with
   `pngquant` to fit), a **demo account**, and submit for review.

Gotcha: the OAuth review path mints a REAL token, so a true "sandbox" (simulated
writes) applies to the API-key path; for the OAuth reviewer, hand a demo account
with no live publishing accounts connected.
