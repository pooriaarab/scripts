# canva-app — build, run, and submit a Canva app

A Canva app is a React app on the **Canva Apps SDK** running in a sandboxed iframe
inside the Canva editor. Unlike Make/Zapier there is no push CLI for submission — you
upload a built bundle in the Developer Portal. This is the playbook: the command
sequence from `integrations/<app>/` to submitted-for-review, plus the traps that each
cost a round-trip. The concept-level skill is `canva-app` in `pooriaarab/skills`.

## Flow

```bash
cd integrations/<app>            # canva app source (src/, manifest/config, assets/)
npm install
npx @canva/cli apps start        # local preview; open it inside Canva via the portal's "Preview"
# ... develop against @canva/app-ui-kit + @canva/design + @canva/intents ...
npm run build                    # produces the bundle to upload
```

Then in `developer.canva.com`:
1. Create the app → copy its **App ID** into the app config.
2. Configuration → allow-list every external origin the app fetches (incl. `localhost` for dev) — **un-allow-listed origins fail silently**.
3. Declare capabilities (design read, asset upload) — match them to the SDK calls exactly.
4. Upload the built bundle; fill the listing (name, description, **512×512** icon, screenshots).
5. **Submit for review** (marketplace) — or keep it private/team for internal use.

## Traps (each = one round-trip)

- **Iframe blocks un-allow-listed fetch** — the #1 "my API hangs" cause. Allow-list the origin in the portal.
- **Design export is async and user-facing** — `requestExport(...)` from `@canva/design` opens Canva's own export UI and resolves to `{ status, exportBlobs }`; handle the `"aborted"` status (user cancelled) and fetch each blob's `url` for its bytes. No synchronous getter.
- **App ID is portal-owned** — a placeholder ID previews fine but fails on submit.
- **Icon must be exactly 512×512**; a fresh reviewer must be able to authenticate from a clean state (self-service auth in-app).

## Files

`example.ts` (next to this README) — the smallest real wiring: export the current design,
upload the rendition, create the downstream action. Copy it as a starting point.
