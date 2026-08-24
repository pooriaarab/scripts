# notion-integration — build, run, and submit a Notion integration

A Notion integration is a service on the **Notion API** (`@notionhq/client`)
that moves content between a workspace and your product's SDK / public REST
API. Distribution requires a **public** integration (OAuth) — internal tokens
are one-workspace only, can never be listed, and can't be converted. This is
the playbook: the path from `integrations/<app>/` to the gallery, plus the
traps that each cost a round-trip. The concept-level skill is
`notion-integration` in `pooriaarab/skills`.

## Flow

```bash
cd integrations/<app>          # integration source (src/, assets/, .env)
cp .env.example .env           # NOTION_CLIENT_ID / NOTION_CLIENT_SECRET / NOTION_REDIRECT_URI
npm install
npm run dev                    # serves OAuth + sync loop on localhost
# open the landing page: connect Notion (OAuth), paste your API key + database id
```

Notion side, at `https://www.notion.so/my-integrations`:
1. Create a **public** integration → copy the client id/secret into `.env`.
2. Register the redirect URI exactly as `NOTION_REDIRECT_URI` (localhost for dev, HTTPS for prod).
3. Set capabilities to only what the code calls (read/update/insert content).
4. Grant content: pick the database on the OAuth consent screen (public), or share it via `…` → Connections (internal).
5. When live: polish name/description/icon → **Distribution → Submit for review** → gallery at `https://www.notion.so/integrations`.

## Traps (each = one round-trip)

- **Internal ≠ public** — internal tokens can't be distributed, listed, or converted. Start public.
- **Grant the content** — `object_not_found` / empty query means the integration can't see the database. Not a bad id.
- **status vs select** — detect the property type via `databases.retrieve`; filter and write syntax differ.
- **Status options must pre-exist** — create them in Notion first; the API auto-creates select options only.
- **Typed envelopes** — join `plain_text` from `title[]`/`rich_text[]`; truncate rich text under 2000 chars; paginate with `start_cursor`.
- **Redirect URI exact match** — byte-for-byte against the registered value, at both authorize and token exchange.
- **No refresh token** — store the access token; a 401 means the workspace uninstalled → re-auth. Back off on 429.

## Files

`example.ts` (next to this README) — the smallest real wiring: OAuth exchange,
query a database for rows at a status (with status/select detection), hand
each row to your API, write the result back onto the row. Copy it as a
starting point.
