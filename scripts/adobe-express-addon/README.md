# adobe-express-addon — build, run, and submit an Adobe Express add-on

An Express add-on is a React panel on the **Adobe Add-on SDK** running in a sandboxed
iframe inside Adobe Express. Submission is a bundle upload in the Adobe Developer
Console (no push CLI). This is the playbook: the command sequence from
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

Then in the **Adobe Developer Console** (Express add-ons):
1. Create the add-on listing.
2. Upload the built bundle; fill name, description, icon, screenshots.
3. Pick distribution: **public** (marketplace review) or **private/link**.
4. Submit for review.

## Traps (each = one round-trip)

- **Iframe blocks un-allow-listed fetch** — declare every external origin (incl. `localhost`) in the manifest allow-list, or the request dies at runtime with a vague network error.
- **Export is async, multi-part** — `addOnUISdk.app.document.createRenditions(...)` returns a Promise of blobs; handle multi-page output.
- **Manifest permissions must match usage** — under-declare and it breaks at runtime; over-declare and review slows.
- **A fresh reviewer must authenticate from a clean state** — self-service auth in the panel.

## Files

`example.ts` (next to this README) — the smallest real wiring: export the current
design, upload the rendition, create the downstream action.
