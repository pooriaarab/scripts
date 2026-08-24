# figma-plugin — build, run, and publish a Figma plugin

A Figma plugin is two programs over `postMessage`: `code.js` in the plugin sandbox
(no DOM, but no CORS) and `ui.html` in an iframe (full DOM, but CORS applies),
declared in `manifest.json` alongside `networkAccess.allowedDomains`. There is no
publish CLI — submission happens in the Figma desktop app / Community site. This is
the playbook: the command sequence from `integrations/<plugin>/` to published, plus
the traps that each cost a round-trip. The concept-level skill is `figma-plugin` in
`pooriaarab/skills`.

## Flow

```bash
cd integrations/<plugin>         # plugin source (src/, manifest.json, assets/)
npm install
npm run build                    # esbuild: src/code.ts -> code.js; src/ui.ts bundled + inlined into ui.html
npm run watch                    # rebuild on change
npm run typecheck
```

Then in the Figma desktop app:
1. **Plugins → Development → Import plugin from manifest…** → select `manifest.json`.
2. Run it: **Plugins → Development → \<plugin name\>**.
3. Store the API key through the plugin's own settings UI — it lands in
   `figma.clientStorage`, sandbox-side, and never enters the iframe.

## Publish

1. `npm run build` and smoke-test: select frame → export → API round trip.
2. **Plugins → Development → Manage plugins → Publish**
   (or `figma.com/community` → **Publish plugin**).
3. First publish assigns a plugin ID — add `"id": "<assigned-id>"` to
   `manifest.json` so every later publish updates the same listing.
4. Fill the listing: name, **128×128** icon, **1920×1080** cover, description
   (state that an API key is required + where to get one), tags, support URL.
5. **Publish** → Figma review before it appears in Community search
   (SLA: TBD — confirm at first submission).

## Traps (each = one round-trip)

- **Fetch in the wrong context** — the #1 "request fails" cause. The sandbox has no
  CORS; the iframe has full CORS. If your API sends no CORS headers, the fetch
  belongs in `code.js`, never in the UI.
- **`networkAccess.allowedDomains`** — every external origin (API, upload CDN,
  image/thumbnail hosts) listed exactly, with scheme; `reasoning` is required.
  Missing = runtime failure, not build failure.
- **No `FormData`/`Blob` in the sandbox** — hand-roll multipart bodies with
  `TextEncoder` + `Uint8Array` (see `example.ts`).
- **UI = one self-contained HTML file** — the build inlines the JS bundle into
  `ui.html` via a placeholder; no external scripts unless allow-listed.
- **Export is async** — `await node.exportAsync(...)` returns a `Uint8Array`.
- **Plugin ID after first publish** — copy it into `manifest.json` or the next
  publish forks the listing.
- **`editorType`** — declare only the editors the plugin supports; reviewers check.

## Files

`example.ts` (next to this README) — the smallest real wiring: sandbox-side frame
export → hand-rolled multipart upload → API call, driven by a `postMessage` intent
from the UI. Copy it as a starting point.
