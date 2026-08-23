# framer-plugin — build, run, and publish a Framer plugin

A Framer plugin is a React app on the **`framer-plugin` npm package** (`@framer/plugin`)
running in an iframe inside the Framer desktop app. Unlike Canva there is no portal
bundle upload or review queue — you zip the build and post it to the Framer Community,
and it publishes near-instantly. This is the playbook: the command sequence from
`integrations/<app>/` to published, plus the traps that each cost a round-trip. The
concept-level skill is `framer-plugin` in the skills repo.

## Flow

```bash
cd integrations/<app>            # framer plugin source (src/, framer.json, public/)
npm install
npm run dev                      # vite + mkcert; prints https://localhost:5173
# ONE TIME: open that https URL in a browser and accept the local certificate,
# or Framer shows a blank panel (Framer refuses plain http://localhost).
# In the Framer desktop app: Plugins menu → enable Developer Tools → open the
# development plugin for that URL.
# ... develop against @framer/plugin (framer.showUI, getImage, setPluginData) ...
npm run build                    # tsc + vite → dist/ (vite-plugin-framer copies framer.json in)
npm run pack                     # zips the CONTENTS of dist/ → <app>-framer-plugin.zip
```

Then publish:
1. Post the zip in the Framer Community (`framer.com/communities/`, Plugins category).
   Published essentially immediately — no lengthy review. This is the platform's big
   selling point; the build traps above are the real work.
2. Framer Marketplace listing is a separate curated step — TBD, confirm the submission
   URL and requirements at first submission.

## Traps (each = one round-trip)

- **Dev server must be local HTTPS** — `vite-plugin-mkcert` + one manual cert-accept in
  a browser. The #1 "my plugin is a white box" cause.
- **`framer.showUI({...})` before `createRoot().render()`** — with explicit
  `width`/`height`, or the panel never sizes. `import "@framer/plugin/framer.css"` too.
- **Selection via the SDK, not the DOM** — `framer.getImage()` /
  `framer.subscribeToImage(cb)` (canvas mode); bytes via `asset.getData()`. Subscribe,
  don't read once — a stale selection ships the wrong image.
- **Zip the CONTENTS of `dist/`** (`zip -r out.zip .` from inside `dist/`) so
  `framer.json` sits at the archive root. Zipping the folder itself fails to load.
- **Plugin data is per project** — `framer.getPluginData`/`setPluginData` are async and
  stored in the Framer project file. Always read on load; gate the UI when no key.
- **No fetch allow-list** — the iframe can call your API directly (team API key as
  Bearer token). Keep business logic server-side; the plugin is a thin client.

## Files

`example.ts` (next to this README) — the smallest real wiring: open the plugin window,
read the current selection image, upload its bytes to your API, create the downstream
action. Copy it as a starting point.
