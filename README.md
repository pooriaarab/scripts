# scripts

Automation scripts that run my agent ops.

## Part of my AI workspace

The [`agents`](https://github.com/pooriaarab/agents) repo is the hub — a portable `.agents` folder symlinked into every agent CLI.

| Repo | What |
|---|---|
| [agents](https://github.com/pooriaarab/agents) | The hub — portable `.agents` workspace |
| [skills](https://github.com/pooriaarab/skills) | Reusable agent skills |
| [clis](https://github.com/pooriaarab/clis) | Working CLIs for ad-platform APIs |
| [commands](https://github.com/pooriaarab/commands) | Slash commands and shortcuts |
| [scripts](https://github.com/pooriaarab/scripts) | Automation scripts |
| [prompts](https://github.com/pooriaarab/prompts) | Refined prompts |

## fleet-ci-census

Wall-time CI census across the fleet. JSON default; `--markdown` ranks by total minutes.
Repos that hit the page cap are marked `(floor)`. Run `./fleet-ci-census --help`.

## Diagnose CI in this order

The four `ci-*` scripts are one workflow, not four tools. Run them in order. Each step
stops you from optimising a job that does not matter.

| Step | Script | Question it answers |
|---|---|---|
| 1 | `ci-pr-latency` | Which number is bad — the wall clock you wait for, or the machine seconds you pay for? They move independently, so never report one CI number. |
| 2 | `ci-job-timings` | Which job is the critical path? Jobs run in parallel, so wall clock is the longest job, not the sum. A win on any other job buys machine time only. |
| 3 | `ci-cache-health` | Do the caches actually hit? A cache that restores nothing still prints a green success line, and a disabled remote cache prints one grey line. |
| 4 | `ci-runner-audit` | Is each job on a tier that can run it? Flags `services:` and `actions/cache` misuse on self-hosted runners. |

Only optimise after step 4. The reasoning behind the order, and the checklist of defects
that hide behind a green check, are in the
[`ci-speed-diagnosis`](https://github.com/pooriaarab/skills/blob/main/ci-speed-diagnosis/SKILL.md)
skill.

```bash
./ci-pr-latency   owner/repo
./ci-job-timings  owner/repo
./ci-cache-health owner/repo --limit 12
./ci-runner-audit owner
```

## Other scripts

Not part of the diagnosis order above.

| Script | What |
|---|---|
| `claude-token-rotate` | Rotate a Claude OAuth token into every repo that runs the review action. Reads the token from a hidden prompt, never an argument, because an argument lands in shell history and the process list. |
| `install-pr-hooks` | Installs the `pr-standards` pre-push hook into local pooriaarab checkouts that have adopted `.github/pr-standards.json`. Dry-run by default; `--apply` writes, `--uninstall --apply` removes. See [pr-standards.md](pr-standards.md). |
| `fleet-digest` | One message a day that needs a person: owner-only label requests, failing default-branch CI, stale PRs and green PRs that wait for a human. Prints `Nothing needs you.` when empty. |
| `fleet-ci-census` | Per repo and workflow: run count, p50/p95 wall time, total minutes, failure and cancellation rates. JSON by default; `--markdown` ranks by total minutes. A run count at the page cap is a floor, not a total. See [fleet-ci-census.md](fleet-ci-census.md). |

## Tests

`.github/workflows/tests.yml` runs every test in this repo on each pull request:
the checker's `node --test` suite, the PreToolUse guard, the prefix builder, the
hook installer, and the branch-pattern check. Each group runs even after an
earlier one fails, so one run names every failure rather than only the first.

Run them locally the same way:

```bash
node --test pr-standards.test.mjs
PATH="$PWD:$PATH" ./hooks/pr-standards-guard.test.sh
python3 build-repo-prefixes.test.py
python3 install-pr-hooks.test.py
./adopt-branch-pattern.test.sh
./pr-standards-rollout-labels.test.sh
```

## pr-standards

Checks a branch or a pull request against the [PR standard](pr-standards.md): one
issue, one PR, one concern, under 500 counted lines. Run it before you push, and let
CI run it again on the PR.

```bash
./pr-standards branch                    # the current branch name
./pr-standards branch cr-142-fix-onboard # a specific name
./pr-standards precheck --branch X --title Y   # pattern only, no network
./pr-standards pr --repo pooriaarab/content-rabbit --number 88
./pr-standards pr --repo pooriaarab/content-rabbit --number 88 --json   # machine-readable
./pr-standards --selfcheck               # run the test suite
```

Exit 0 clean, 1 on a failure, 2 on a configuration problem. Warnings never change
the exit code.

Settings come from `.github/pr-standards.json` in the repo being checked. If that
file does not set a prefix, the checker reads the bundled `repo-prefixes.json`
registry. A repo absent from both sources gets a prefix derived from its name,
which it reads from `GITHUB_REPOSITORY` or the origin remote rather than the
directory name. A worktree is checked out to a directory you named, so the
basename is only the last resort.

Two files, not one. `pr-standards` is a launcher and `pr-standards.mjs` holds the
engine, which is also what the test suite imports. Anything fetching this checker
needs both.


## Other scripts

| Script | What |
|---|---|
| `box-reap` | Report what ascii.dev Boxes are costing and stop the unused ones. Never reaps on Box state, which lies |
| `box-guard` | Give every Box a deadline. `box new --no-auto-stop` leaves `archiveAfter: null` and nothing will ever stop it. Repairs state hourly with `box extend --ttl`; never stops anything |
| `box-reap-cron` + `com.pooriaarab.box-reap.plist` | Runs `box-reap` hourly under launchd. Installs to `~/.local/bin` because macOS TCC blocks a launchd agent from reading `~/Documents` |
| `turbo-remote-cache/` | Deployable Cloudflare Worker: a Turborepo remote cache backed by R2 |
| `box-setup/` | Provision the personal agent-CLI roster (claude x3, codex, gemini, kimi, pi, muse) inside an ascii.dev Box |
| `box-warm-shim` | Stand in for the `box` CLI so crabbox can start a Box from a named environment and a warm snapshot |
| `box-repo-audit` | Per-repo readiness for a warm Box: package manager, tracked files, gzipped tree size, secrets manifest, turbo creds, existing env and snapshot. `--tsv` for parsing |
| `box-session` | SessionStart/SessionEnd hook: warms a Box for the repo in the background when a session starts, stops it when the session ends. Opt-in per repo via `.crabbox-default-on` |
| `box-perf-check` + `box-perf-cron` + `com.pooriaarab.box-perf.plist` | Time the attach path and flag regressions against a baseline, weekly. Catches the silent 50x slowdowns |
| `box-work` | Start or reuse a Box that is ready to work on a repo, and run the work there instead of on the laptop. `box-work <repo>`, `--agent pi "brief"`, `--ssh`, `--stop`, `--list`, `--stop-all` |
| `box-env-provision` | Give a repo a warm `box env`: repo auto-clone, the env files its `.crabbox-secrets` declares, `TURBO_*`, credentials capped. `--all --private-only` does the whole account |
| `box-git-sync.sh` | Runs inside a Box that already has the repo: fetches the commit the laptop is on instead of uploading a tree |
| `box-fast-attach` | Attach a worktree to a running Box in ~2s over `box host`, instead of ~84s through crabbox |
| `box-unpack.sh` | Runs inside a Box: unpacks the delta `box-fast-attach` sends and installs only when the lockfile moved |
| `agent-defect-rate` | Defect rate per `Assisted-by` agent: how often merged PRs get reverted or hot-fixed within the window. Shows the denominator next to every rate |

## pr-standards-rollout

Enforce a standard branch name and PR title format across the account.
Every PR branch looks like `<prefix>-<issue>-<slug>`, and every PR title
starts with `[<PREFIX>-<ISSUE>]`. The prefix is 2-4 lowercase letters
mapped from the repo name in `repo-prefixes.json`.

Derivation rules: hyphen/underscore/dot separated names take the first
letter of each part (up to 4). Single-word names take the first 3 letters.
Names that are already an initialism are hand-picked. When two repos
collide on the same prefix, extend the shorter one until they differ.
Collision resolution is the whole point of the registry: every prefix
must be unique across the account.

| Script | What |
|---|---|
| `repo-prefixes.json` | Prefix registry. One entry per eligible repo. All unique. |
| `pr-standards-rollout` | Fan the standard out. Dry-run by default. `--apply` to write. |
| `pr-standards-templates/` | The four artifacts each repo gets: config, PR template, workflow, and the managed `AGENTS.md` block. |

```bash
./pr-standards-rollout                   # dry-run all repos
./pr-standards-rollout --repo <name>      # dry-run one repo
./pr-standards-rollout --repo <name> --apply  # write + PR
```

The rollout creates or reuses a GitHub issue per repo, then a branch and a PR.
Repos that are already configured are skipped.

## Notes

| Doc | What |
|---|---|
| `box-cost-discipline.md` | How to keep ascii.dev Boxes cheap, and why `state: idle` is not an idleness signal |
| `box-warm-start.md` | Where the ~77s Box attach actually goes, and what a warm snapshot does and does not buy |
| `t3-code-on-a-box.md` | Running T3 Code on a Box and reaching it over `box host` |
| `silent-failover-discipline.md` | Why a working primary/backup credential failover can take a whole fleet down silently, and what to alert on instead |
- [cloudflare-auth-discipline.md](cloudflare-auth-discipline.md) — why wrangler, OAuth and the Cloudflare MCP cannot mint an API token, the one permission that can, and how to mint narrow per-purpose tokens that do not break on custom domains.

## Agent routing

The agent-worker roster lives in [agent-routing.json](agent-routing.json): three
tiers (`route:mechanical`, `route:scoped`, `route:judgement`) mapped to workers
with cost and benchmark indexes, plus an `unavailable` list with reasons. Not
every worker has a `command`: the default `route:judgement` worker is the
native Claude Code session doing the reviewing, not a CLI invocation, so it has
none. Tier names are durable; model names and prices are not, so update the
JSON instead of editing CLAUDE.md copies that drift. Retune tier defaults from
`agent-defect-rate` output, not vibes.
