# canva-app — build, run, and submit a Canva app

A Canva app is a React app on the **Canva Apps SDK** running in a sandboxed iframe
inside the Canva editor. Unlike Make/Zapier there is no push CLI for submission — you
upload a built bundle in the Developer Portal. This is the playbook: the command
sequence from `integrations/<app>/` to submitted-for-review, plus the traps that each
cost a round-trip. The concept-level skill is `canva-app` in `pooriaarab/skills`.

## Flow

```bash
export PATH="/opt/homebrew/opt/node@20/bin:$PATH"   # see the Node note below
cd integrations/<app>            # canva app source (src/, config, assets/)
npm install
npx @canva/cli apps link         # writes CANVA_APP_ID into .env from the portal
npx @canva/app-scripts dev       # dev server
npx @canva/cli apps preview      # opens the running app in a new Canva design
# ... develop against @canva/app-ui-kit + @canva/design + @canva/intents ...
npx tsc --noEmit                 # the bundler does NOT typecheck -- run this yourself
npx @canva/app-scripts build     # -> dist/app.js, the bundle you upload
```

**`@canva/cli` has no `build` and no `start`.** Its whole surface is
`create/list/link/preview/doctor/migrate/config`; both build and dev live in
`@canva/app-scripts`. A `package.json` with `"build": "@canva/cli apps build"` looks
plausible, fails, and — because the build never runs — hides every type error in the app.

**Node:** `@canva/app-scripts` declares `node>=22` but builds fine on 20, and the other
marketplace CLIs (`vsce`, `ovsx`, Coda `packs`) segfault on 22+. Pin 20 for all of them and
ignore the EBADENGINE warning.

Then in `developer.canva.com` (portal-review, free — no publish CLI; `@canva/cli` is preview only):
1. Create the app → `npx @canva/cli apps link` (or set `CANVA_APP_ID` in `.env`). The App ID
   lives in the environment, not in source.
2. Configuration → allow-list every external origin the app fetches (incl. `localhost` for dev) — **un-allow-listed origins fail silently**.
3. Declare capabilities (design read, asset upload) — match them to the SDK calls exactly.
4. Upload the built bundle; fill the listing. Assets: **512×512** PNG icon (1:1, full-bleed, no
   transparency/rounded corners), a **2400×1800** (4:3) featured image (up to 2 in a carousel),
   app support + privacy-policy URLs, and a **test-account login** if the app authenticates.
5. **Submit for review** (marketplace) — or keep it private/team for internal use. Cap: 5
   submissions per app per day.

## Traps (each = one round-trip)

- **Iframe blocks un-allow-listed fetch** — the #1 "my API hangs" cause. Allow-list the origin in the portal.
- **Design export is async and user-facing** — `requestExport(...)` from `@canva/design` opens Canva's own export UI and resolves to `{ status, exportBlobs }`; handle the `"aborted"` status (user cancelled) and fetch each blob's `url` for its bytes. No synchronous getter.
- **App ID is portal-owned** — a placeholder ID previews fine but fails on submit.
- **The bundler does not typecheck.** `app-scripts build` succeeds over broken types, so a
  wrong build script means `tsc` has never run on the app. Run it before every submit.
- **Icon must be exactly 512×512** with **no alpha channel**; a fresh reviewer must be able
  to authenticate from a clean state (self-service auth in-app).
- **Stripping alpha needs a real rasteriser.** `sips` renders SVG to PNG but always keeps an
  alpha channel, and a JPEG round-trip adds visible artifacts to flat brand colour. Use
  sharp's `.flatten({ background })`:
  ```bash
  node -e 'require("sharp")("icon.svg",{density:600}).resize(512,512,{fit:"fill"})
    .flatten({background:"#7857ed"}).png().toFile("icon-512.png")'
  ```
  Render the icon from a **square, unclipped** source. The rounded-corner variant most brand
  kits ship as the app/PWA icon is exactly what Canva rejects.
- **oxlint's autofix can outrun your `lib`.** If the repo lints on commit, its `prefer-*`
  autofixes may rewrite `.sort()` to `.toSorted()`; on `lib: ES2022` that does not compile,
  so the file can never be committed. Raise `lib` to ES2023 rather than fighting the fixer.

## Files

`example.ts` (next to this README) — the smallest real wiring: export the current design,
upload the rendition, create the downstream action. Copy it as a starting point.
