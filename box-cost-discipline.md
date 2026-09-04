# Keeping ascii.dev Boxes cheap

A Box bills every second it is powered on. A stopped Box is free. Nothing turns
a Box off for you except its TTL, so the whole cost problem is one habit: turn
the machine off when the work is done.

The `box-reap` script in this repo reports what is burning and stops what is
not being used. This page is the convention it enforces.

## The five rules

**1. Always pass a `--ttl`, and size it to the worst case.**

```bash
box new --type small --ttl 3600
```

The TTL is a hard wall-clock deadline, not an idle timer. It counts from
creation or resume and never from your last activity, so a Box with a one-hour
TTL stops one hour later **even in the middle of a build**. Size it to the
longest the job could plausibly take, not the average. The default is one hour.

**2. Stop the Box yourself when the work finishes. Do not wait for the TTL.**

The TTL is a backstop for a caller that crashed. It is not the shutdown
mechanism. A job that finishes in 4 minutes under a 1-hour TTL wastes 56
minutes of credit.

```bash
box new --type small --ttl 1800 --json | ...   # capture the id
trap 'box stop "$BOX_ID"' EXIT                 # stop on any exit path
```

**3. Prefer `small` unless the job is CPU-bound.**

| Type | vCPU | RAM | Rate | Cost per hour |
|---|---|---|---|---|
| `small` | 2 | 4 GB | 0.5x | $0.018 |
| `default` | 4 | 8 GB | 1x | $0.036 |
| `large` | 8 | 16 GB | 2x | $0.072 |

A `large` Box left running for a day costs the same as four `small` ones. Most
agent work is I/O-bound and does not notice the difference.

**4. `box stop`, not `box delete`.**

Stopping snapshots the filesystem and pauses billing. `box resume` brings the
Box back with its files intact. Delete only when the filesystem is genuinely
disposable, because deletion is permanent.

**5. Long jobs write a heartbeat.**

This is what lets an automated reaper tell your build apart from an abandoned
machine. Costs nothing, and it is the only fully reliable signal:

```bash
# in the Box, alongside the real work
while :; do touch /home/user/.box-reap-heartbeat; sleep 30; done &
```

Or opt a Box out of reaping entirely:

```bash
touch /home/user/.box-reap-keep
```

## The four layers, and what each one knows

Box cost control is four layers. Each knows strictly less than the one before.

| # | Layer | Mechanism | What it knows | How it acts |
|---|---|---|---|---|
| 1 | Creation | `box-guard` | whether a Box has a deadline (`archiveAfter`) | gives an unbounded Box a TTL in place with `box extend --ttl`; see "The unbounded Box, and why the guard is not a rule" |
| 2 | Session | `box-session`, wired to the Claude Code SessionStart/SessionEnd hooks | which repo claimed which Box (`~/.local/state/box-work/<repo>.id`) | warms one Box per repo; the last session out stops it and keeps the id so the next session resumes instead of creating; see "Stop keeps the id, so the next session resumes" |
| 3 | Laptop | `box-reap` via launchd, every 15 minutes | CPU, load, and the heartbeat file inside the Box, over SSH | the only layer that decides with evidence: it probes each Box and stops it only when the probe says quiet; see "Why \"idle\" is a trap" |
| 4 | Cloud | `box-sweep-remote` in `.github/workflows/box-sweep.yml`, on a GitHub-hosted runner every 30 minutes | age alone | cannot SSH into a Box, so it decides on age alone; report-only on a schedule, stopping only on a `workflow_dispatch` with `execute: true`; see "The laptop reaper cannot run while the laptop sleeps" |

The layers are ordered by how much they know, and **a layer must never act with more
confidence than its evidence supports.** The cloud layer's age rule is crude, and it is
safe only because it defaults to reporting.

What each layer misses, all of it recorded in the sections below:

- **Creation:** a Box created with `--no-auto-stop` has `archiveAfter: null`, and nothing
  stops it until `box-guard` gives it a deadline.
- **Session:** a session killed before SessionEnd never runs `box-session end`, so its claim
  file stays behind and shields the Box until the claim TTL expires.
- **Laptop:** `box-reap` cannot run while the laptop is asleep, which is when a forgotten
  Box bills longest.
- **Probing:** a Box the reaper cannot reach over SSH produces no CPU or heartbeat evidence,
  so the reaper must not stop it — and on 2026-09-02 two such Boxes reached 51.7h and 65.4h,
  about $4.20 between them, before the cloud layer's age rule caught them.

## Why "idle" is a trap

`box list` reports a state of `idle` for almost every Box you will ever look at.
It is not an activity signal, and reaping on it destroys live work.

The vendor docs are explicit: `idle` and `running` "only reflect work queued
through `POST /boxes/{boxId}/prompt` … a box can show `idle` while your own
agent works inside it."

That is reproducible. A Box pegged at 100% CPU for four minutes, driven over
`box exec`, reported `state: idle` in every one of ten samples, and its
`updatedAt` never moved — not during the load, and not after a `box extend`
either. `updatedAt` only moved when a Box-managed prompt was queued.

So `box-reap` never decides on state alone. It measures CPU utilisation inside
the Box, and it prefers the heartbeat file when one exists. On a 2 vCPU Box, an
unused machine reads 0-10% CPU and one busy core reads 50-60%, which separates
cleanly. The 1-minute load average does not: unused reads 0.12-0.29 and busy
reads 0.42-0.65, which overlaps.

The honest limit: an I/O-bound job, such as a long `npm install`, uses little
CPU and looks like an unused Box. Write the heartbeat, or run the reaper with
`--require-heartbeat` so it only ever touches Boxes that opted in.

## Running the reaper

Report only. Changes nothing:

```bash
box-reap
```

Plan a reap. Still changes nothing:

```bash
box-reap --stop-idle-older-than 2h
```

Actually stop them:

```bash
box-reap --stop-idle-older-than 2h --execute
```

Strictest mode, for when heartbeats are wired up everywhere:

```bash
box-reap --stop-idle-older-than 2h --require-heartbeat --execute
```

## Optional: run it on a schedule

**`./box-reap-install` installs the cron job** (launchd, every 15 minutes by default).
It copies the reaper to `~/.local/bin`, copies the credential to `~/.config/ascii-box/env`,
writes and loads both agents, then verifies the agent is actually alive rather than
trusting `launchctl load`. Idempotent, so re-run it after changing the scripts.

### Stop keeps the id, so the next session resumes

`box-work` has always known how to resume: if the recorded Box is `stopped` or `archived`
it resumes it instead of creating one. That branch was **unreachable**, because both
stoppers deleted the id file immediately after a successful stop. box-work cannot resume
what it can no longer see, so every session cycle created a brand-new Box — which is where
the creation storm came from, not from any single runaway caller.

Both stoppers now keep the id. A stopped Box is free and keeps its snapshot, so a kept id
costs nothing, and the next start resumes in ~4s instead of paying ~100s and a creation
slot (the platform caps creations per minute and per day, so slots are a real resource).

The id is never forgotten automatically. A failed resume or an unrecognized `info` state
can mean the Box is truly gone, or just a transient hiccup talking to the account — and
guessing wrong on the side of deleting throws away a resumable Box forever, which is the
exact bug this section fixes. So box-work refuses to guess: it logs and exits rather than
falling through to create. There is no code path that tells the two cases apart, so if the
Box really is gone this is not self-healing — the next start hits the same unresolved state
and refuses again. Run `box info <id>` yourself; if it confirms the Box is gone, `rm
~/.local/state/box-work/<repo>.id` to let the next start create a fresh one.

### Unclaimed Boxes are the ones that actually accumulate

`box-session` records the Box it warmed for a repo in
`~/.local/state/box-work/<repo>.id`. Any other running Box is **unclaimed**: a session
ended without stopping it, or someone ran a bare `box new`. Nothing will ever claim it
again, so it bills until its archive deadline.

Measured 2026-08-30 on this account: **14 running Boxes, 2 claimed, 12 unclaimed.** The
credit check projected a **$287 overrun** inside a 15-day window. One sweep took it to 5
Boxes and roughly a third of the burn.

So `box-reap-cron` sweeps unclaimed Boxes at a shorter age (`BOX_REAP_ORPHAN_AGE`, default
15m) than claimed ones (`BOX_REAP_AGE`, default 45m). Age is the only thing that changes:
being unclaimed never stops a Box by itself, the probe still has to find it quiet. That is
a weaker guarantee than it sounds — an I/O-bound job uses little CPU, so anything that
matters must touch the heartbeat file (see the section above). Unclaimed is evidence about
intent, not about activity, and the two must not be confused.

### There are two claim namespaces, and only one of them stopped anything

`box-session`/`box-work` claim a Box in `~/.local/state/box-work/<repo>.id`. But
`crabbox-attach` — the `git worktree add` wrapper — **also** creates a Box, and records it
in the worktree as `.crabbox-slug`, holding a slug rather than a `bx_` id. Nothing that
stops Boxes ever read that file.

That cut both ways. Those Boxes were never stopped by anything, and they also looked
unclaimed to the sweep, so a Box a live worktree was attached to could be stopped while its
session was thinking rather than building. `box-reap-cron` now resolves worktree slugs
against the live Box list (matching `subdomain` or `name`) and treats a match as claimed. A
slug with no match is a stale marker from a Box that is already gone, and is ignored — most
of the ones on this machine are exactly that, left over from the GCP-era leases.

A worktree claim also ages out, at the same `BOX_REAP_CLAIM_TTL_MIN`. Removing a worktree
takes its `.crabbox-slug` with it, so that case reaps itself; the case the TTL covers is a
worktree that still exists while nobody has touched it for hours, whose Box would otherwise
be shielded forever. Six such slugs were shielding nothing real on the first run.

**A claim is only trustworthy while its session lives.** If a session is killed before
`box-session end` runs, its `.id` file stays behind, and a stale claim would shield that
Box from every later sweep — forever. So a claim expires: past `BOX_REAP_CLAIM_TTL_MIN`
(default 360, i.e. 6h) the Box is treated as unclaimed and logged as such. Expiring in that
direction is the safe one, because the probe still gates the stop.

Expect a few "failed to stop: Box is archived" lines in a sweep. That is a Box that hit its
own archive deadline between the plan and the execute. Archived Boxes are free; nothing is
wrong.
Start in dry-run for a few days and read the log before adding `--execute`:

```cron
# every 15 minutes, report only
*/15 * * * * PATH=$HOME/.ascii/bin:$PATH box-reap --stop-idle-older-than 2h --json >> ~/.box-reap.log 2>&1

# once you trust it, add --execute. Keep --require-heartbeat: unattended
# reaping without it can stop an I/O-bound job that never opted in.
# */15 * * * * PATH=$HOME/.ascii/bin:$PATH box-reap --stop-idle-older-than 2h --require-heartbeat --execute --json >> ~/.box-reap.log 2>&1
```

Drop `--require-heartbeat` only once every long-running job on the account
writes a heartbeat. Until then it is the difference between a reaper that
cleans up and one that interrupts work while you are asleep.

In `--json` mode stdout stays a single parseable document; stop progress goes
to stderr, so `box-reap --json ... | jq` works even with `--execute`.

`box-reap` exits 0 on a clean run, 1 on error, and 3 when a warning fired, so a
monitor can alert on 3. The warnings cover credit projected to run out before
the billing period ends, the 100-Box concurrency cap, the creation rate limits,
and any Box running with auto-stop disabled.

`box` must be on `PATH`; cron does not read your shell profile.

## The laptop reaper cannot run while the laptop sleeps

`box-sweep-remote` is the same policy for a machine that is not this one: list Boxes, group
them by age against a hard ceiling (default 6h), report, and stop the over-age ones only
with `--execute`.

It deliberately knows less than the laptop reaper. A CI runner cannot SSH into a Box, so it
cannot measure CPU or load; deciding on age alone is cruder, which is exactly why the
default is report-only and why the ceiling is six hours — no agent session legitimately
holds a Box that long unattended. It stops, never deletes, and a Box with
`archiveAfter: null` is called out separately, because nothing will ever stop that one on
its own.

It shells out to the `box` CLI rather than the HTTP API, on purpose. Hand-rolling the API
means guessing a base URL, and a wrong guess makes an enumeration failure look identical to
an empty account — the one wrong answer that looks calm. (`api.ascii.dev` does not resolve;
that was the first attempt, and it "found" zero Boxes.)

**Wired to CI**, and it does not need the CLI. Installing `box` on a runner was the wrong
problem: `box status` reports the API base the CLI itself uses, and the endpoints work with
curl and an API key.

```
box status  ->  "config": { "apiUrl": "https://ascii.dev", "channel": "prod" }

GET  https://ascii.dev/api/box/boxes            200, same JSON shape as `box list --json`
POST https://ascii.dev/api/box/boxes/{id}/stop  stop
```

Verify a route exists before trusting it. A missing route answers
`{"error":"Not Found","path":"/..."}`, while a real route with a bad id answers
`{"error":"not_found"}` — that distinction is how the stop path was confirmed without
stopping anything.

**The API is not the CLI, and the difference bites.** `GET /api/box/boxes` returns every
Box the account has ever had, including `stopped` and `archived`; `box list` hides those by
default (`--filter` defaults to running). The first API run reported **100 Boxes burning
$3.636/hour**, when five were running and the real figure was $0.180/hour. The report now
counts only billing states (`idle`, `running`, `pending`, `stopping`, `ready`).

`.github/workflows/box-sweep.yml` runs it every 30 minutes on `ubuntu-latest`,
report-only, with a `workflow_dispatch` input to actually stop. The first real run found two
Boxes at **39h and 52h old** — claimed Boxes whose session state kept being refreshed, so
the laptop reaper never touched them. That is precisely the gap this backstop exists for.

## The periodic reaper (added 2026-08-28, tightened 2026-08-30)

Nothing was stopping Boxes. `com.pooriaarab.crabbox-sweep` existed but was
**not loaded** in launchd, ran once a day at 09:00, still defaulted to
`provider=gcp`, and did not scan `~/Documents/Personal`.

`com.pooriaarab.box-reap` replaces it, installed by `./box-reap-install`. It started
hourly with `--stop-idle-older-than 45m --execute`; since 2026-08-30 it runs **every 15
minutes** and sweeps unclaimed Boxes too, because hourly could not keep up — Boxes were
created faster than a 45-minute threshold checked once an hour could catch them. The
decision still goes through the CPU/load/heartbeat checks and never reaps on Box state.

**macOS TCC is the trap.** A launchd agent cannot read `~/Documents` without
Full Disk Access granted by hand. The first install failed with
`Operation not permitted` and launchd exit code 126 — and the job still showed
up as registered, so `launchctl list` alone did not reveal it. The reaper and
its credential therefore live outside the protected paths:

```
~/.local/bin/box-reap        ~/.local/bin/box-reap-cron
~/.config/ascii-box/env      (mode 600, the API key)
~/.local/state/box-reap/reap.log
```

Verify a change actually took, rather than trusting `launchctl load`:

```
launchctl kickstart -k "gui/$(id -u)/com.pooriaarab.box-reap"
launchctl list | grep box-reap        # second column must be 0, not 126
tail ~/.local/state/box-reap/reap.log # the timestamp must advance
```


## The unbounded Box, and why the guard is not a rule (2026-08-28)

`box new --no-auto-stop` creates a Box with `archiveAfter: null`. No TTL will
ever fire and the platform will never stop it. Five accumulated in a single
afternoon, all idle at load 0.00, on track for roughly $155/month.

It surfaced only because `box-reap-cron` started propagating the reaper's exit
status. `launchctl list` began showing `exit=3` and the log said:

```text
WARNING: auto-stop is OFF on 2 Box(es) (...); nothing will ever stop them.
```

Before that fix the wrapper always exited 0 and nobody would have known.

**The fix cannot live at the call site.** `box` is a plain binary that any
agent, script or session can invoke, and the zsh `box()` wrapper exists only in
an interactive shell. A convention every caller must remember is not a control.

So `box-guard` repairs the state instead. It sweeps for Boxes with no deadline
and gives them one with `box extend --ttl`, which sets the remaining lifetime on
a **running** Box in place — no stop, no restart, so it cannot interrupt real
work. It runs every 15 minutes from `box-reap-cron`, before the reap.

Two things checked while diagnosing this, both worth keeping:

- **`box resume` does NOT drop the TTL.** Create with `--ttl 900`, stop, resume:
  `archiveAfter` is still set. Resume keeps whatever the Box had, so a Box
  created with `--no-auto-stop` stays unbounded across resumes.
- **`box new` with no `--ttl` is fine.** It reports `ttlSeconds: 3600` and sets
  `archiveAfter` an hour out. The default is safe; only the explicit flag is not.
