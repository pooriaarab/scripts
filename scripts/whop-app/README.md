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
Then in the Whop dashboard: create the app → set the hosted URL + OAuth redirects →
test via the dev proxy → submit a versioned build for review → promote to the App Store.

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
