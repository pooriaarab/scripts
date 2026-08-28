# Making ascii.dev Boxes fast for every personal repo

Measured 2026-08-28. Every number here came from a real run, not from the docs.

## The headline: we were optimising the wrong thing

The brief assumed a Box takes ~65s to come up and that a warm image would cut
that to ~1s. The first half is right. The second half is not, and the reason
matters.

A Box is **already** ~1s to ready and ~2s to first usable command:

| run | ready | first usable command |
|---|---|---|
| cold 1 | 1.0s | 2.1s |
| cold 2 | 1.3s | 2.6s |
| cold 3 | 0.8s | 2.0s |

Provisioning was never the bottleneck. Here is where the 65s actually goes,
captured from a real `git worktree add` firing the crabbox hook on
replytosocial (693 files, 3.9 MiB):

```
lease (box new + provision) ....... 14.3s
bootstrap ......................... 10.1s
sync .............................. 48.7s   <-- the real cost
    rsync 19.7 | ssh 7.6 | finalize 4.5 | git_seed 4.0
    manifest_write 4.1 | fingerprint_remote 3.7 | prune 3.7
command (apt check + bun install) . 14.9s   (bun install itself 7.2s)
-------------------------------------------
total ............................. 1m16.8s
end to end ........................ 1m38.3s
```

**Two thirds of the wait is rsyncing the worktree to the box.** Dependency
install was 15s of 77s. So a snapshot that only caches `node_modules` fixes the
smaller half of the problem.

### A warm start is slower to first command, not faster

This is the counter-intuitive result and it is worth stating plainly:

| | ready | first usable command |
|---|---|---|
| cold (`base`) | 0.8-1.3s | 2.0-2.6s |
| warm (`--from` a 651MB snapshot) | 0.9-1.0s | **6.6-9.1s** |

Restoring the filesystem costs time. The warm box wins overall because it skips
install entirely, not because it boots faster. Anyone promising "1s warm boxes"
is quoting `ready`, which is not a number you can do work in.

## What was actually broken

### 1. Secrets: a box that comes up misconfigured, not broken

crabbox copies gitignored files to the box before installing. With no
`.crabbox-secrets` manifest it copies the worktree root only. For Content
Rabbit that meant the 5-key root `.env.local` went up and the **221-key**
`apps/website/.env.local` did not. The box installed cleanly and then failed at
runtime, which is the worst shape for an agent to debug.

Manifests now exist for all four repos. They list paths only, hold no values,
and are committed.

| repo | manifest contents | PR |
|---|---|---|
| content-rabbit | `.env.local`, `apps/website/.env.local` | #921 (merged earlier) |
| replytosocial | `.env.local`, `backend/.dev.vars` | #206 |
| imecore | `.env.local`, `apps/web/.env.local`, `apps/web/cloudflare/app-worker/.dev.vars` | #98 |
| popcornteam | `.env.local` | #252 |

Two judgement calls worth recording:

- **replytosocial `backend/.env.local` is deliberately excluded.** It holds live
  Stripe keys and the production BYOK encryption key. Nothing in `backend/src`
  or `scripts/` reads any of its six names — the runtime reads the unsuffixed
  names from `.dev.vars`. A box does not need them to build, and a box is a
  third-party VM, so they stay on the laptop.
- **imecore lists two files with identical contents** (`apps/web/.env.local` and
  `apps/web/cloudflare/app-worker/.dev.vars`). That is not redundancy: Next.js
  reads one and wrangler reads the other. Dropping either misconfigures one
  runtime.

### 2. Turbo remote cache: configured, never used

The credentials already reached the box inside the root `.env.local`, but
nothing exported them and the remote script never ran turbo. Every build was
cold. Proof, on a real box, of the gap and the fix:

| run | state | result |
|---|---|---|
| A | as crabbox leaves it today | `Remote caching disabled` · 0 cached · **6.022s** |
| B | `TURBO_*` exported | `Remote caching enabled` · miss, populates remote · 6.718s |
| C | local `.turbo` **deleted** | **2 cache hits from remote** · **605ms** · `FULL TURBO` |

Run C is the one that counts. The local cache was destroyed first, so the hit
could only have come from the remote. Ten times faster.

The fix is now a named `box env` per repo carrying `TURBO_API`, `TURBO_TOKEN`
and `TURBO_TEAM`, verified injected into the box environment.

### 3. crabbox cannot ask for a warm box — and the shim that fixes it

This is the blocker nobody had hit yet. crabbox shells out to `box`, but it
forwards exactly three ascii-box settings:

```
-ascii-box-base-url   -ascii-box-cli   -ascii-box-workdir
```

There is **no** way to pass `--environment` or `--from`. So every crabbox
warmup starts from the bare `base` image no matter what snapshots exist.

`-ascii-box-cli` is the seam. `scripts/box-warm-shim` stands in for the `box`
binary, injects the two flags on `new`, and passes every other subcommand
through untouched. No crabbox change needed.

Two traps cost real time here, both silent:

- crabbox calls `box --no-update --json --api-url https://ascii.dev new --ttl 900`.
  The subcommand is **not** `$1`, and a naive "first bare word" scan picks up
  `https://ascii.dev` — the *value* of `--api-url`. The shim then passes through
  and you get a cold box that looks completely fine.
- crabbox runs `box` with `HOME` pointed at its own state directory, so
  `$HOME/.ascii/bin/box` does not exist. Resolve the real home from the OS user.

Verified end to end: box pinned to environment `replytosocial` v5, **732MB of
`node_modules` restored**, `TURBO_*` present, warmup 17.1s.

### 4. The base image already has the toolchain (and crabbox already knows)

The base image ships `node` 24, `bun` 1.3.14, `git`, `gh`, `gcc`, `make`,
`python3`, `pkg-config`, `rg`, `jq`, `docker`, `ffmpeg`, Chrome, plus Go, Rust,
Java, Ruby and PHP.

My first reading of `crabbox-attach.sh` was that its apt-install step was pure
waste on every attach. **That was wrong.** The step is guarded by
`command -v curl / git / gcc`, and all three are present, so it never fires.
Verified on a real box:

```
curl /usr/bin/curl   git /usr/bin/git   gcc /usr/bin/gcc
VERDICT: crabbox apt block SKIPS
```

So there is nothing to cut here. The 14.9s "command" phase is the package
manager install (7.2s of it `bun install`) plus overhead, not apt. Worth
recording because it is the obvious-looking optimisation that is not there.

## Cost and reaping

The docs settle the question the CLI only hinted at. `box new --no-auto-stop`
implies a default auto-stop, and there is one — but it is **purely a TTL**:

> "Box has no idle timer. The auto-stop TTL counts from creation or resume,
> never from last activity." — docs.ascii.dev/box/faq

Default TTL is 1 hour, max 30 days. At expiry a box **stops and snapshots**; it
is not deleted. So the standing rule holds: nothing stops a Box for being
unused, and the caller must `box stop`.

**Webhooks cannot help.** `box webhook` fires on `ready`, `error`, `archived`
and `hydrated` only. There is no idle or activity event, so lifecycle hooks
cannot drive an idle reaper. Do not wire them for that.

`box-reap` in this repo already does the right thing: it never reaps on state,
because a Box pegged at 100% CPU still reports `idle`. It measures CPU and load
and prefers a heartbeat file. That stays the reaping mechanism.

Plan `box_20`: 100 concurrent, **50 starts/hour**, 150/day. The hourly start
ceiling — not the concurrency cap — is what limits an agent fleet.

## Security

- **`box env list` prints stored secret-file contents in plaintext.** Anything
  parked in an environment's secret files is readable by anyone who can run the
  CLI. That is why the repo environments carry `TURBO_*` **only**, and app
  secrets keep going up the per-run crabbox sync path instead.
- Every repo environment sets `--box-credentials false --agents-credentials false`.
  A build box needs neither the Box CLI credentials nor the agent logins, and
  one compromised box otherwise exposes the whole personal AI spend surface.
- **Scrub secrets before snapshotting.** A snapshot is a filesystem image and
  outlives a key rotation. The `replytosocial-ready` snapshot was scrubbed of
  `.env.local` and `.dev.vars` first; the environment injects config at boot
  instead. Verified: a box deployed from it has no secret files and full
  `node_modules`.
- **Zero data retention and warm snapshots are mutually exclusive.** Enabling
  ZDR deletes existing named snapshots and blocks creating new ones. Pick one.
  We keep snapshots and do not enable ZDR.

## Gotchas that cost time

- **`sizeBytes` on a named snapshot is not the restored size.** Ours reported
  32,830 bytes and restored 651MB. Snapshots are incremental deltas on a chain.
  Do not judge a snapshot by that number — deploy from it and look.
- **ascii's GitHub token is a scoped app token.** It 404s on any repo not
  connected in the ascii dashboard, so `box env add-repo pooriaarab/content-rabbit`
  fails and an in-box `gh repo clone` of it fails too. Connect the repo in the
  dashboard, or push the source from the laptop.
- **Max 10 named snapshots per account.** Four repos is fine; a snapshot per
  worktree is not. Refresh by saving the same name again; the old artifact is
  released and boxes already deployed from it are unaffected.
- **A green exit proves nothing here.** Three separate steps in this work exited
  0 while doing nothing: the shim passing through on a mis-parsed subcommand,
  `box new --json` emitting JSONL that a single-object parser dropped (which
  leaked three billing boxes), and the pi+OpenRouter grok worker producing zero
  bytes in 20 minutes. Verify by inspecting the result, always.

## What to adopt, and what to skip

Worth wiring:

- **`box env`** — one named environment per repo. Already done for all four.
- **`box snapshot` / `--from`** — the dependency cache. Real win, via the shim.
- **`box exec --detach`** — runs past the 600s exec cap; poll with
  `--status <pid>`, logs at `~/.ascii/processes/<pid>.log`.
- **`box scp`** — works, and is the simplest way to push a file to a box.
- **`box limits`** — check `starts.hour.remaining` before any fan-out.

Not worth wiring, with reasons:

- **`box webhook`** — no idle event. Cannot drive reaping. That was the only
  reason we wanted it.
- **`box data-retention`** — mutually exclusive with named snapshots. The
  snapshots are worth more than delete-on-stop.
- **`box host` / `box forward`** — useful for a human debugging a dev server,
  irrelevant to an unattended build box. `forward` does not survive a resume.
- **`box org` / `box team`** — single-user personal account, one wallet. Nothing
  to scope.
- **`box desktop`** — no use for a build box.
- **`box api-key`** — one key already exists and works. Rotate, do not automate.
- **`--type large`** — twice the price, and measurably not faster.

## Getting the attach from ~84s to ~2s

The warm snapshot was a wash because it attacks install, which is the small
half. The transport is the big half. Round trips against a running Box:

| transport | round trip | usable as a payload channel? |
|---|---|---|
| `box exec` | 1.13 / 1.17 / 1.31 s | **No.** It silently DROPS a large argument. A 43k-char base64 blob arrived as 1 byte, and the box reported `gzip: unexpected end of file`. It exits 0 on the way in. |
| `box ssh`  | 5.17 / 5.17 / 5.72 s | Yes, and it takes stdin. This is the honest floor for anything SSH-based. |
| `box scp`  | 6.05 / 6.14 / 9.83 s | Yes, but it rides SSH too, so it is no better. |

Streaming a tar into `box ssh` gives a working ~6.7s attach. Good, not 2s.

**`box host` is the way through.** It publishes a Box port on a stable HTTPS URL
that never touches SSH. Put a small receiver on that port, POST the tree to it,
and let it extract and decide about installing:

```
attach 1:  2.23s   attach 4:  1.82s
attach 2:  1.99s   attach 5:  1.86s
attach 3:  1.87s
```

Five consecutive runs, tar build included, `extract_rc=0` each time, and the
change verified by reading a marker back off the box over a different
transport. About **45x faster than crabbox's ~84s**.

`scripts/box-fast-attach` plus `scripts/box-attach-receiver.py` implement this.
Setup costs ~10s once per Box; every attach after that is ~2s. Install is
skipped unless the lockfile hash actually moves.

### Two bugs in this that are worth remembering

Both produced a confident, fast, wrong answer:

- **`set -o pipefail` plus `cat` on absent lockfiles.** `cat bun.lockb ...`
  returns non-zero for the files that do not exist, pipefail fails the whole
  pipeline, and `set -e` kills the script at that line. It exits in 0.4s and
  looks like a very fast success. Feed `cat` only the files that exist.
- **HTTP/1.1 keep-alive on a single-threaded receiver.** One idle connection
  blocks the next request until it times out, which turned the 1.7s attach into
  a consistent 90s. The timing looked stable, so it read as a real measurement
  rather than a bug. Use `ThreadingHTTPServer` and send `Connection: close`.

## Still open

- **Content Rabbit has no warm snapshot yet.** Its repo is not connected to the
  ascii GitHub app, so the box cannot clone it. Either connect it in the
  dashboard or seed the snapshot by pushing the tree from the laptop once.
- **The 49s rsync is untouched.** It is now the dominant cost by a wide margin.
  A snapshot that already contains the repo checkout would turn the full sync
  into a delta; that is the next real win, and it is bigger than the install
  saving we just banked.
- **The shim is not yet wired into `crabbox-attach.sh`** for every repo.
