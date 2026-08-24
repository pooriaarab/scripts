# wix-app — build + submit a Wix app

React dashboard page on the Wix SDK (`@wix/sdk`, `@wix/dashboard`). Concept skill:
`wix-app` in `pooriaarab/skills`.

## Flow
```bash
cd integrations/<app>
npm install
npm run build             # tsc --noEmit && vite build
```
Submit at `dev.wix.com` (portal-review, free — no publish API; `@wix/cli` deploys
code, not the listing):
1. Configure extensions, OAuth scopes, redirect URLs; host over HTTPS (valid SSL).
2. Fill the listing (name, teaser, description, keywords) + media: **5–6
   screenshots, min 1200×900 px 4:3**; optional promo banner **540×360 px**; demo
   video via YouTube URL. Privacy-policy + terms URLs if the app handles user data.
3. Supply a **live demo account + credentials** and install notes for review.
4. Clear all dashboard **blockers** → **Submit & Publish**. An AI review runs on
   submit, then a Wix human review; SLA up to ~15 business days (locked meanwhile).
5. On fail, new AI blockers appear — fixing alone doesn't clear them; **resubmit**.

## Traps
- **`import.meta.env` untyped** → add `src/vite-env.d.ts` with `/// <reference types="vite/client" />`
  or tsc errors TS2339.
- If `vite.config.ts` is in both the app tsconfig and a composite node tsconfig → **TS6305**;
  keep it only in the node project, `include: ["src"]` for the app.
- Wix OAuth authorizes Wix data; your API needs its own key (per-installation).

## One call
```ts
import { createClient } from "@contentrabbit/sdk";
const cr = createClient({ apiKey });
await cr.posts.create({ platformType: "twitter", content: "Hello from Wix" });
```
