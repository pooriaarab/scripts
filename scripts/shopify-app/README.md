# shopify-app — build, run, and submit a Shopify app

A Shopify app is a Remix embedded app (App Bridge + Polaris) on
`@shopify/shopify-app-remix`, configured by `shopify.app.toml`. Submission is NOT
CLI-only: the CLI deploys config, but review happens from the Partner Dashboard.
This is the playbook: the command sequence from `integrations/shopify-app/` to
submitted-for-review, plus the traps that each cost a round-trip. The
concept-level skill is `shopify-app` in the skills repo.

## Flow

```bash
cd integrations/shopify-app      # app source (app/, shopify.app.toml, .env)
npm install
cp .env.example .env             # SHOPIFY_API_KEY / SHOPIFY_API_SECRET / SHOPIFY_APP_URL / SCOPES
npx shopify app config link      # binds the dir to the Partner app, writes client_id into the toml
npm run dev                      # shopify app dev — tunnel, URL sync, installs on your dev store
# ... develop: routes under app/routes/, Polaris UI in App Bridge, your product's API in .server.ts ...
npm run typecheck && npm run build
npx shopify app deploy           # push shopify.app.toml (webhooks, scopes, URLs) — REQUIRED after any toml edit
```

Then in the Partner Dashboard (`partners.shopify.com`) — portal-review, free.
`shopify app deploy` releases an app *version*, it does NOT submit for review:
1. Apps → Create app (once) → copy Client ID/secret into `.env` + `client_id` in `shopify.app.toml`.
2. Host the production build on a public HTTPS URL (valid SSL); set `SHOPIFY_APP_URL`, update `application_url` + `redirect_urls`, `shopify app deploy` again.
3. **Apps → [app] → Distribution → Shopify App Store**: set primary language, complete configuration (app URLs, GDPR webhooks, app icon, emergency contact); if you touch buyer data, complete the **protected customer data** request.
4. Listing assets: **1200×1200 icon** (no text), **1600×900 feature image**, **3–6 screenshots at 1600×900**, a **demo screencast** (English/subtitled), public **privacy-policy URL**.
5. Run the **automated checks** (+ optional AI self-review) → **Submit for review** — reviewers install on a test store with none of your state. Reviews run 2+ weeks. After approval, the App Store distribution goes live.

## Traps (each = one round-trip)

- **Webhook route must 2xx after the HMAC check passes** — catch downstream errors; Shopify retries non-2xx into a webhook storm.
- **GDPR webhooks are mandatory**: `customers/data_request`, `customers/redact`, `shop/redact`. No-ops are fine if you store no buyer data; `shop/redact` + `app/uninstalled` must wipe the shop's settings/sessions.
- **toml edits are dead until `shopify app deploy`** — the #1 "webhook never fires" cause. New scopes force merchant re-auth.
- **Embedded root route needs `boundary.error` + `boundary.headers` exports** (`@shopify/shopify-app-remix/server`) or OAuth redirects die in the iframe; pass the API key to `<AppProvider isEmbeddedApp apiKey>`.
- **Session storage**: dev SQLite file → production needs DB-backed storage; lost sessions = OAuth loops on every click.
- **Review runs with zero state**: every page needs a working "connect your account" state; privacy-policy URL is required for the listing.

## Files

`example.ts` (next to this README) — the smallest real wiring: `shopifyApp()`
server config plus a webhook route that authenticates, calls your product's REST
API best-effort, and always returns 200. Copy it as a starting point.
