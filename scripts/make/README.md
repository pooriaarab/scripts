# make — publish a custom app from `app.json`

`publish-app.py` pushes a bundled `app.json` to a Make (Integromat) custom app over the
SDK Apps API. **Make has no whole-`app.json` import** — a custom app is stored as
separate components (base, connection, webhooks, modules, RPCs) and the UI makes you
build/paste each one. This script does it in one run instead.

## Why

Pasting ~40 components (each with 4–5 sub-sections) by hand in the Make UI is slow and
error-prone. The SDK API can create every module/webhook/RPC and set each section
programmatically. Prefer this over manual paste.

## Prereqs

1. The app **shell** exists in Make (UI: More → Custom apps → Create custom app). You
   need its slug (e.g. `content-rabbit-xvboes` — it's in the app editor URL).
2. A **connection** exists on the app (create once in the UI). The script reuses the
   first one, or pass `--connection <name>`.
3. A **Make API token** with scopes `sdk-apps:read` + `sdk-apps:write`
   (Profile → API/Access → Add token).

## Use

```bash
MAKE_TOKEN=xxxxxxxx python3 publish-app.py \
  --app my-app-slug \
  --app-json ./app.json \
  --version 1 \
  --zone us1.make.com        # eu1.make.com etc for other zones
# optional: --connection my-conn  --pause 1.5  --push-base  --dry-run
```

`--dry-run` prints the writes without making them. `--push-base` also PATCHes the base
section (baseUrl/headers/log). Start with `--dry-run` to sanity-check the plan.

## `app.json` shape

Top-level keys map 1:1 to Make components:

| key | Make component |
| --- | --- |
| `base` | Base (baseUrl, headers, log.sanitize) |
| `connection` | Connection (reused, not recreated) |
| `webhooks[]` | Webhooks (attach/detach/parameters) |
| `modules[]` | Modules — `kind`: `action` \| `search` \| `instant_trigger`; name `makeApiCall` → universal |
| `rpcs[]` | Remote procedures (dropdown data) |

## API facts baked in (learned the hard way)

- Auth header is `Authorization: Token <token>`.
- **Modules & RPCs are versioned** (`/apps/{app}/{ver}/modules`), **webhooks are not**
  (`/apps/{app}/webhooks`, sections at `/apps/webhooks/{name}/{section}`), and so are
  connections (`/apps/{app}/connections`).
- Module `typeId`: 1 = trigger (poll), 4 = action, 9 = search, 10 = instant trigger
  (converger), 11 = responder, 12 = universal (returner).
- Section set: `PUT .../modules/{name}/{api|expect|interface|samples|...}` with the raw
  section JSON. `api` ← communication, `expect` ← mappable parameters.
- **Rate limit** shows up as HTTP `403` with body code **`1010`**. The script paces
  (default 1.5s) and backs off 30s on `1010`. Note: failed calls still count against
  the bucket, so don't hammer it — raise `--pause` if you keep hitting 1010.
- **attach/detach** reference connection params as `{{account.paramName}}` (not
  `{{connection.*}}`) and do **not** inherit base, so the script writes them with an
  absolute URL + explicit `Bearer {{account.apiKey}}` header.
- Make **auto-names** created webhooks (often after the app slug); the script captures
  the real name from the create response and links instant-trigger modules to it.

## Idempotency

Re-running skips modules/RPCs that already exist (by name) and webhooks that already
exist (by label). To re-push a component, delete it first
(`DELETE /apps/{app}/{ver}/modules/{name}`).
