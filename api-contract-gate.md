# The API contract gate

An OpenAPI spec is a claim. This gate checks the claim against the running
service on every pull request, and it costs nothing to run.

Use [`scout-gate.sh`](scout-gate.sh). It wraps
[scout](https://github.com/tester-army/scout) and works around two upstream
quirks that otherwise make the gate unusable.

## Why scout and not the rest of that vendor's stack

Scout is genuinely open source. Full `src/` on GitHub, MIT, no obfuscation, no
account, no API key. A source audit found exactly two `fetch()` call sites:
loading the spec, and calling the API under test. There is no telemetry.

Its sibling browser-QA CLI is not the same thing. That package declares MIT, but
the source repository it names does not exist publicly, its npm build script
ends in an obfuscation step, and it needs an API key to reach a paid service.
Check for a real `src/` before you trust a licence field.

## What it actually finds

A sweep runs four probe kinds against every operation in the spec.

| Probe | What it asserts |
| --- | --- |
| `happy-path` | The documented success response, validated against its schema |
| `missing-auth` | The operation rejects a caller with no credentials |
| `invalid-auth` | The operation rejects a well-formed but wrong credential |
| `not-found-shape` | A 404 body matches the documented error envelope |

`missing-auth` is the one that earns its keep. It finds an operation that forgot
its authorization check, which no amount of happy-path testing finds.

## Safe against a live deployment

Mutations are refused unless `--allow-mutations`. Requests are pinned to the
base-URL host. No cross-host redirects. Remote `$ref` resolution is disabled.
Rate limit defaults to 5 per second, budget to 300 requests per run. Responses
are capped at 1 MiB and returned as a bounded preview. Credentials resolve from
the environment at request time and are redacted from output.

Narrow it further per repo. `"allowedMethods": ["GET"]` in `scout.json` makes
the read-only property structural rather than a flag someone can forget.

## Where the gate belongs

| Gate | Trigger | Target |
| --- | --- | --- |
| Pre-PR | before opening the pull request | local dev server |
| PR CI | after the preview deploys | the preview URL |
| Release | tag or production deploy | production, read-only |

**Put the CI gate in its own job.** If it shares a job with the deployment
lifecycle, a failed probe can trip the teardown step and delete the deployment
you need in order to debug the failure. That is a real trap, not a theoretical
one: a preview workflow that cleans up `on: failure()` will eat its own
evidence.

Size the runner small. The job waits on HTTP, so it needs no cores.

## The two traps

### `--ci` defaults the coverage floor to 100

`scout report --ci` sets `--min-coverage` to 100 when you do not pass it. No
sweep can satisfy that. A gate without an explicit floor can never go green, and
the failure reads as `coverage-below-minimum`, which looks like a coverage
problem rather than a defaulting problem.

Always pass `--min-coverage`.

### `scout init` silently drops the rate limit and the budget

`scout init` rewrites `scout.json` from its command-line flags. It preserves
`allowedMethods`, `allowedPaths`, `authProfiles` and `headers`. It drops
`policy.rateLimit` and `policy.budget`, because `buildConfig` has no spread for
them.

So a deliberately low rate limit set for a fragile API is reset to 5 on the next
`init`, and nothing says so. It also overwrites `baseUrl`, which leaves a
localhost URL staged after a local run.

Two ways to live with it. Leave those keys out of the file and rely on the
defaults, so nothing looks effective that is not. Or snapshot and restore the
file around the run. `scout-gate.sh` does both.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Pass |
| 1 | A finding at or above the severity threshold |
| 2 | Usage error |
| 3 | Incomplete run |

Incomplete reasons are `no-sweep-run`, `coverage-below-minimum` and
`no-probes-recorded`.

Fuzz findings arrive as candidates. They do not gate until confirmed with
`scout finding confirm`, so a noisy fuzz run cannot break CI on its own.

## Auth

Pass credentials as a literal `$VAR` string in single quotes. Scout expands it
at request time and redacts it from output, so the secret stays out of the
process table and out of logs.

```sh
scout sweep --header 'Authorization: Bearer $API_TOKEN'
```

Behind Cloudflare Access, use a service token as two headers:

```sh
scout sweep \
  --header 'CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID' \
  --header 'CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET'
```

The Access policy needs a Service Auth rule that allows that token.

## Reading the coverage number honestly

An unauthenticated sweep proves that operations reject anonymous callers. It
does not exercise a successful authenticated response. `happy-path` only means
something once an auth profile exists.

The denominator also moves with the policy. Restricting to `GET` makes coverage
a percentage of GET operations, not of the whole spec. Say which you mean.

Worked result from the first repo to adopt this: a 134-path, 183-operation
OpenAPI 3.1 spec, policy restricted to `GET`. A full sweep ran 149 probes with 0
errors and reached 97 percent of the 71 GET operations. The floor was then set
at 90.

## Requirements

Node 22.12 or newer. `scout.json` must sit in the working directory; scout does
not search parent directories, so run from the repo root.

Scout writes runtime state to `.scout/` with mode 0700 and appends it to
`.gitignore` itself. Add the report artifact to `.gitignore` too.

## Repos without a spec

Scout has a spec-less `--base-url` mode, but it gives much weaker probes and no
schema validation. Generating a spec is the prerequisite, not an afterthought.

For a Next.js App Router project, `app/api/**/route.ts` gives you the path and
the method mechanically. Request and response schemas are not mechanically
derivable unless the handlers already validate with a schema library you can
introspect. Be honest about that split rather than shipping a spec whose
response bodies are invented.
