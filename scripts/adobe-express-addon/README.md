# adobe-express-addon — build, run, and submit an Adobe Express add-on

An Express add-on is a React panel on the **Adobe Add-on SDK** running in a sandboxed
iframe inside Adobe Express. Submission is a package upload in the **Adobe Developer
Distribution** portal (no push CLI). This is the playbook: the command sequence from
`integrations/<app>/` to submitted, plus the traps that each cost a round-trip. The
concept-level skill is `adobe-express-addon` in `pooriaarab/skills`.

## Flow

```bash
cd integrations/<app>                 # add-on source (src/, manifest.json, assets/)
npm install
npx @adobe/ccweb-add-on-scripts start # HTTPS local preview; load it inside Express (add-on dev mode)
# ... build the React panel against addOnUISdk ...
npm run build                         # produces the bundle to upload
```

Then in the **Adobe Developer Distribution** portal (portal-review, free):
1. One-time: create a **Publisher Profile** (public name, site, description, **250×250 px** logo).
2. Create the add-on listing; upload the packaged bundle.
3. Pick distribution: **public** (in-app Marketplace, full assets) or **private/link** (one 36×36 icon, no listing).
4. Public assets: icons **36×36 / 64×64 / 144×144 px**, **1–5 screenshots at 1360×800 px**, **privacy-policy URL** + EULA + support contact; test credentials (with credits) if the add-on gates features.
5. **Submit for review** — human review, target 10 business days (often 2–3).

## Traps (each = one round-trip)

- **Iframe blocks un-allow-listed fetch** — declare every external origin (incl. `localhost`) in the manifest allow-list, or the request dies at runtime with a vague network error.
- **Export is async, multi-part** — `addOnUISdk.app.document.createRenditions(...)` returns a Promise of blobs; handle multi-page output.
- **Manifest permissions must match usage** — under-declare and it breaks at runtime; over-declare and review slows.
- **A fresh reviewer must authenticate from a clean state** — self-service auth in the panel.

## Files

`example.ts` (next to this README) — the smallest real wiring: export the current
design, upload the rendition, create the downstream action.
