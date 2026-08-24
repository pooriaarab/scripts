# wix-app — build + submit a Wix app

React dashboard page on the Wix SDK (`@wix/sdk`, `@wix/dashboard`). Concept skill:
`wix-app` in `pooriaarab/skills`.

## Flow
```bash
cd integrations/<app>
npm install
npm run build             # tsc --noEmit && vite build
```
Register in the Wix Dev Center (OAuth, permissions, dashboard URL) → submit. AI pre-check
(minutes) then human review (~business weeks).

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
