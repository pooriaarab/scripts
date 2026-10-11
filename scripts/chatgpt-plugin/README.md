# ChatGPT plugin submission

Submits a directory's hosted MCP server to the OpenAI plugin directory
(Platform → Plugins → Upload new or existing plugin). One ZIP per site.

Requires: a verified developer identity on the Platform dashboard, the site's
`/mcp` endpoint live, and Cloudflare API access for domain verification.

## Build

```sh
node build.mjs sites/private-repo-f838-fyi.json out/
# -> out/private-repo-f838-fyi.zip
```

`sites/*.json` fields: `slug`, `domain`, `display_name`, `subtitle`,
`long_description`, `capabilities`, `prompts`, `category`, `logo`,
`screenshot`. `logo`/`screenshot` are machine-local paths resolved at build
time — point them at the site repo's `brand/` directory.

The builder fails loudly on the checks that burned live attempts:

- `subtitle` > 30 chars → "Subtitle must be 30 characters or fewer"
- `display_name` without the domain brand → "name is too generic"
- pricing words in `long_description` → "Remove pricing, subscription offers,
  and temporary promotions from the description"

## Portal flow

1. Upload the ZIP. The validator parses `.codex-plugin/plugin.json`; a
   generic `display_name`, missing `interface`/`author`, or a missing `logo`
   each produce a finding. Fix the config, rebuild, re-upload.
2. **MCPs → Connect → Domain verification** shows a token that must be
   served as plain text at
   `https://<domain>/.well-known/openai-apps-challenge`.
3. Serve the token (see below), click **Verify Domain**, then **Connect**
   and **Continue**. The tool scan lists every tool.
4. **Submit for review** → check all six attestations → **Submit**.

The submit call returns 400 "Wait for the attached app's review" while the
app-level review runs (~10–30 min). Retry after the server row leaves
`Draft`; the listing then flips to `In review`.

## Domain verification

The sites run on **Workers custom domains**, which bypass zone Worker
routes — a `*/.well-known/...` route never fires. Snippets are not enabled
on the plan. What works: a redirect rule, because `http_request_dynamic_redirect`
runs before the Workers fetch stage.

```sh
CLOUDFLARE_API_TOKEN=... sh setup-challenge.sh <zone_id> <domain> <token>
```

Each call merges the token into the worker's `OPENAI_TOKENS` var and adds a
302 rule on the zone pointing at `<worker>.workers.dev/?h=<domain>`.
OpenAI's verifier follows the redirect. Repeat per domain; the worker and
rules are permanent (re-verification and future sites reuse them).

## Traps seen live

- An abandoned draft holds its MCP URL — a second draft with the same URL
  gets "already used by another app". Delete the old draft via the
  three-dot **More plugin actions → Delete plugin** menu.
- Inside the Connect dialog, click **Connect** once (registers) then
  **Continue** (closes). Two steps, easy to miss the second.
- The attestation checkboxes are `[role=checkbox]` spans — `.click()` works,
  but the Submit button stays disabled until all six are `aria-checked=true`.
- One MCP server per plugin. Renaming the server in `.mcp.json` on an
  existing draft is rejected: "Adding, removing, or replacing an MCP server
  isn't supported."
- `demo_recording_url` in `plugin.json` is optional at upload time and
  required for MCP review — the site's `/developers` page is accepted as a
  URL value, but a real video may be requested by the review team.
