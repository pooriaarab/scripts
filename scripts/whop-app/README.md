# whop-app — build + submit a Whop app

React app embedded as an iframe view inside a Whop (Whop SDK). Concept skill:
`whop-app` in `pooriaarab/skills`.

## Flow
```bash
cd integrations/<app>
npm install
npx whop-proxy            # dev proxy: loads the local app inside a real Whop
npm run build             # bundle served at your hosted app URL
```
Submission (portal-review; no dev fee). `POST /apps` can create the app record
(`name`, `company_id`, `base_url`, `route`, `icon`, `redirect_uris`), but the
`marketplace_status` transition has no endpoint — you publish in the dashboard:
1. `dev.whop.com` → create the app; set the HTTPS `base_url`/`route` + redirect URIs.
2. Fill the listing: name, icon, description, **2–3 screenshots**, **10–20 s demo
   video**. Preview at `whop.com/apps/<app_id>`.
3. Set visibility **live** (needs name + icon + description) → **Publish to App
   Store**. Review checks the billing/entitlement flow; on pass it goes live.

Revenue: dev rev-share **10–30%**, or a one-time install fee, or a per-member sub.
Whop's platform cut on top, icon px, and review SLA are not in the docs `(verify)`.

## Traps
- **Whop OAuth ≠ your API's auth.** "Sign in with Whop" identifies the user; your own API
  still needs its own key (stored per-installation).
- App ID + redirects are dashboard-owned (placeholders break on install).
- Cast web-only CSS props to a real `CSSProperties` value, not `as unknown as string` (tsc fails).

## One call every app makes
```ts
import { createClient } from "@contentrabbit/sdk";
const cr = createClient({ apiKey });                 // your key, NOT the Whop token
await cr.posts.create({ platformType: "twitter", content: "Shipped!" }); // platformType is a STRING
```
