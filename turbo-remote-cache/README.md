# turbo-remote-cache

Cloudflare Worker that implements the Turborepo Remote Cache API, backed by R2.

This is the shared remote cache for the monorepos. Cold cloud VMs and
vendor-hosted runners point at it via `TURBO_API` so they hit the same
cache the warm self-hosted host populates.

## API

| Method | Path | Behaviour |
|---|---|---|
| `GET` | `/v8/artifacts/:hash?teamId=&slug=` | Return artifact bytes (`application/octet-stream`) or `404` |
| `PUT` | `/v8/artifacts/:hash?teamId=&slug=` | Store request body as artifact |
| `POST` | `/v8/artifacts/events` | Telemetry no-op — `200` empty body |
| `GET` | `/v8/artifacts/status` | `{ "status": "enabled" }` |

All routes require `Authorization: Bearer <TURBO_TOKEN>` (timing-safe compare).
`x-artifact-tag` on PUT is persisted as R2 `customMetadata` and echoed on GET —
required for Turborepo's signed-artifact verification.

Objects are keyed as `<teamId|slug|default>/<hash>` so two teams or two repos
cannot read each other's cache entries. Hashes are validated against
`^[A-Za-z0-9_-]{1,256}$` and rejected with `400` if they contain `.` `/` or
other unsafe characters.

## Prerequisites

- Cloudflare account with Workers and R2 enabled (`R2` requires billing, free tier includes 10 GB).
- `wrangler` CLI (`npm i -g wrangler` or `npx wrangler`).

## Setup

### 1. Create the R2 bucket

```bash
wrangler r2 bucket create <your-bucket-name>
# example: wrangler r2 bucket create my-turbo-cache
```

Then edit `wrangler.jsonc` and replace `YOUR_R2_BUCKET_NAME` with the real
bucket name. The placeholder is intentional — do not commit a real bucket name
until you own it.

### 2. Set the secret

```bash
# From inside turbo-remote-cache/
wrangler secret put TURBO_TOKEN
# paste a long random token, e.g. `openssl rand -hex 32`
```

`TURBO_TOKEN` is the only secret. It is read from `env.TURBO_TOKEN` at runtime;
never put it in `wrangler.jsonc` `vars`.

### 3. Deploy

```bash
npm install
npm run deploy
# wrangler prints the Worker URL, e.g. https://turbo-remote-cache.<subdomain>.workers.dev
```

Note the URL — that is your `TURBO_API`.

### 4. (Optional) Local dev

```bash
npm run dev
# serves at http://localhost:8787 with a local R2 simulation
```

## Wire a consumer repo

In the repo that runs `turbo` (locally or in CI), set:

```bash
TURBO_API=https://turbo-remote-cache.<subdomain>.workers.dev
TURBO_TOKEN=<same token you set with wrangler secret put>
TURBO_TEAM=<teamId or slug that scopes the cache key>
```

Where they go:

- **Local dev** — `.env` / `.env.local` or `export` in your shell before `turbo run`. `TURBO_TEAM` can be any stable string per repo (e.g. the repo slug).
- **CI** — repo or org secrets / environment variables. Example (GitHub Actions):

  ```yaml
  env:
    TURBO_API: ${{ secrets.TURBO_API }}
    TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
    TURBO_TEAM: ${{ vars.TURBO_TEAM }}
  ```

  Or if the CI already sets `TURBO_API` and `TURBO_TOKEN`, only add `TURBO_TEAM`.

- **Vercel-hosted Turborepo** — Project → Settings → Environment Variables. `TURBO_API` must be the full Worker URL (no trailing slash), `TURBO_TOKEN` the bearer secret.

Turbo reads `TURBO_API` as the base URL and appends `/v8/artifacts/...` itself.
If the env vars are absent, Turbo silently falls back to local-only caching —
the cache is a pure speedup, never a hard requirement.

### Verify

```bash
# should return {"status":"enabled"}
curl -H "Authorization: Bearer $TURBO_TOKEN" "$TURBO_API/v8/artifacts/status"

# cache miss → 404, cache hit → 200 after a `turbo run`
curl -i -H "Authorization: Bearer $TURBO_TOKEN" "$TURBO_API/v8/artifacts/<hash>?teamId=$TURBO_TEAM"
```

## Local tests

```bash
npm install
npm test
```

## Security notes

- Auth uses a constant-time (`timingSafeEqual`) comparison over UTF-8 bytes to
  avoid timing side-channels. Do not change it to `===`.
- Hashes are validated before interpolation into R2 keys to prevent path
  traversal.
