# Cloudflare token discipline

Getting a Cloudflare API token to a coding agent looks trivial and is not. This
records what is actually true, so the next person does not spend a session
rediscovering it. Everything here was established by direct testing against the API.

## Nothing in the usual toolchain can mint a token

This is the fact that costs the most time, because four plausible routes all fail
the same way and none of them says why.

| Route | Mints a token? | What actually happens |
|---|---|---|
| `wrangler` CLI | No | `wrangler auth create` makes a local auth *profile*, not an API token. There is no mint command. |
| A `wrangler` OAuth session | No | `POST /user/tokens` returns `Unauthorized to access requested resource` |
| The Cloudflare MCP server | No | Authenticates with the same OAuth scopes, so it fails identically |
| An account-owned token | No | There is no API-Tokens permission in the account scope at all |
| A user token with `User → API Tokens → Edit` | **Yes** | The only thing that works |

Minting is user-scope only. A human creates the first token in the dashboard. Treat
that as a deliberate gate rather than an obstacle: it means an agent cannot mint
credentials for itself out of nothing.

## Keep the minter minimal

Give the minting token the mint permission and nothing else.

That works because **a minted token may hold permissions the minting token does
not.** Delegation is bounded by the account owner's permissions, not the minter's —
verified by minting a Pages-Write token from a minter that had no Pages permission.

So adding permissions to the minter buys nothing and only widens what a leak costs.
Store it in one file, mode 600, and never copy it into a repo, an `.env`, or a CI
secret.

## The names end in Write, not Edit

The dashboard says `Edit`. The API says `Pages Write`, `D1 Write`,
`Workers Scripts Write`, `Workers KV Storage Write`, `Queues Write`.

Resolve names against `GET /user/tokens/permission_groups` and fail **before**
minting on an unknown name. Otherwise you mint a token quietly missing the
permission it was asked for, and debug it at deploy time as a code problem.

## Derive permissions from bindings, not from names

Read the repo's wrangler config and map what is there:

| Binding | Permission |
|---|---|
| `d1_databases` | D1 Write |
| `kv_namespaces` | Workers KV Storage Write |
| `r2_buckets` | Workers R2 Storage Write |
| `queues` | Queues Write |
| `ai` | Workers AI Write |

Add `Account Settings Read` everywhere. Do not add anything "just in case" — that is
how you end up with one broad token wearing a dozen different names.

## Custom domains need a second, zone-scoped policy

**This one breaks everything at once if you miss it.** A worker whose wrangler config
declares `routes` or a `custom_domain` calls the zone API during deploy. An
account-scoped token passes every permission check you are likely to run and then
fails at deploy.

Grep the configs before minting:

```sh
grep -rlE '"?(routes|route|custom_domain)"?[[:space:]]*[:=]' --include='wrangler*' .
```

Any hit needs a second policy scoped to all zones, carrying `Workers Routes Write`
and `Zone Read`:

```json
"policies": [
  {"effect":"allow","resources":{"com.cloudflare.api.account.<ID>":"*"},
   "permission_groups":[ ...account perms... ]},
  {"effect":"allow","resources":{"com.cloudflare.api.account.zone.*":"*"},
   "permission_groups":[ ...zone perms... ]}
]
```

In one fleet, 9 of 12 repos needed this.

## Verify both ways before installing

Confirm the new token **can** do the thing it is for, and **cannot** do something
adjacent. A token that passes only the positive test may just be the broad token
under a new name.

```sh
curl -s -H "Authorization: Bearer $T" .../accounts/$A/d1/database   # expect OK
curl -s -H "Authorization: Bearer $T" .../accounts/$A/r2/buckets    # expect denied
```

Note `/user/tokens/verify` works for API tokens only. For an OAuth session it returns
`Invalid API Token` even while the session is live — an easy false negative to
misread as a dead credential. Check `GET /accounts` instead.

## Do not hand-refresh a wrangler OAuth session

You can POST the stored refresh token to the OAuth endpoint and get a working
one-hour access token. It is a trap: **the refresh token rotates and the old one dies
immediately**, so discarding the response bricks `wrangler` until someone runs
`wrangler login` interactively.

Use `wrangler auth token`. It retrieves the current credential and handles rotation.

## Finding an existing token on a machine

Search `.env*` and `.dev.vars*` with **no depth limit** — a live token can sit five
directories down — and then **verify every candidate**. A revoked token looks
identical to a live one, so finding the dead one first produces a confident wrong
conclusion that the machine has no credential at all.

## A leaked token is only fixed by revoking it

If a token reaches a git history you do not control, rewriting that history is not a
fix you can rely on. Revocation is immediate and total; it is the only step that
actually ends the exposure.

Two things make revocation safe to do quickly, and both are worth building **before**
you need them: per-purpose tokens, so revoking one credential affects one job; and a
check of what actually consumes it, so you know the blast radius rather than guessing.

Debug notes are a common leak path. A file written while fixing an auth problem tends
to contain the real value rather than a placeholder, and it is exactly the kind of
file nobody thinks to scrub.
