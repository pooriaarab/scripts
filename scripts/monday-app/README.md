# monday-app — build + submit a monday.com app

React board/item view on the monday apps SDK (`monday-sdk-js`). Concept skill:
`monday-app` in `pooriaarab/skills`.

## Flow
```bash
cd integrations/<app>
npm install
npm run build             # tsc --noEmit && vite build
```
Submit via the monday Developer Center (portal-review, free — no publish API; the
`@mondaydotcomorg/apps-cli` deploys code, not the listing):
1. `apps.developer.monday.com` → Create app → build the view, set OAuth scopes +
   HTTPS hosting URL (or host on monday-code).
2. Listing assets (exact px): app + developer icon **192×192**, card image
   **592×348**, **3–5 gallery images 1920×960**, demo video **30–60 s MP4 ≤50 MB**.
   Copy limits are hard (name ≤30, short desc ≤60). App terms required.
3. App's **Share** tab → generate the `auth.monday.com` install link → complete the
   marketplace **submission form** (`forms.monday.com`). First response ~72h.

Payments run through monday billing; rev-share 0% until $200k lifetime, then 85/15.
Security questionnaire/SOC2 is optional (Shield Badge only, not required to list).

## Traps
- **monday's session token ≠ your API's auth** — carry your own key (per-installation).
- **`import.meta.env` untyped** → add `src/vite-env.d.ts` (`vite/client` reference).
- Board context arrives via `monday.listen("context")`; the view is a sandboxed iframe.

## One call
```ts
import { createClient } from "@contentrabbit/sdk";
const cr = createClient({ apiKey });
await cr.posts.create({ platformType: item.platform, content: item.text });
```
