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

| Script | What |
|---|---|
| `box-reap` | Report what ascii.dev Boxes are costing and stop the unused ones. Never reaps on Box state, which lies |
| `box-reap-cron` + `com.pooriaarab.box-reap.plist` | Runs `box-reap` hourly under launchd. Installs to `~/.local/bin` because macOS TCC blocks a launchd agent from reading `~/Documents` |
| `turbo-remote-cache/` | Deployable Cloudflare Worker: a Turborepo remote cache backed by R2 |
| `box-setup/` | Provision the personal agent-CLI roster (claude x3, codex, gemini, kimi, pi, muse) inside an ascii.dev Box |
| `box-warm-shim` | Stand in for the `box` CLI so crabbox can start a Box from a named environment and a warm snapshot |
| `box-repo-audit` | Per-repo readiness for a warm Box: package manager, tracked files, gzipped tree size, secrets manifest, turbo creds, existing env and snapshot. `--tsv` for parsing |
| `box-env-provision` | Give a repo a warm `box env`: repo auto-clone, the env files its `.crabbox-secrets` declares, `TURBO_*`, credentials capped. `--all --private-only` does the whole account |
| `box-git-sync.sh` | Runs inside a Box that already has the repo: fetches the commit the laptop is on instead of uploading a tree |
| `box-fast-attach` | Attach a worktree to a running Box in ~2s over `box host`, instead of ~84s through crabbox |
| `box-unpack.sh` | Runs inside a Box: unpacks the delta `box-fast-attach` sends and installs only when the lockfile moved |

## Notes

| Doc | What |
|---|---|
| `box-cost-discipline.md` | How to keep ascii.dev Boxes cheap, and why `state: idle` is not an idleness signal |
| `box-warm-start.md` | Where the ~77s Box attach actually goes, and what a warm snapshot does and does not buy |
| `t3-code-on-a-box.md` | Running T3 Code on a Box and reaching it over `box host` |
| `silent-failover-discipline.md` | Why a working primary/backup credential failover can take a whole fleet down silently, and what to alert on instead |
