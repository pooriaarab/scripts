# monday-app — build + submit a monday.com app

React board/item view on the monday apps SDK (`monday-sdk-js`). Concept skill:
`monday-app` in `pooriaarab/skills`.

## Flow
```bash
cd integrations/<app>
npm install
npm run build             # tsc --noEmit && vite build
```
Build the app in the monday Developer Center (features, OAuth scopes, hosting URL) →
submit for marketplace review.

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
