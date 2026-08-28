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

## Scripts

| Script | What |
|---|---|
| `ci-runner-audit` | Inventory which runner tier every job is on (`self-hosted` / `cloud` / `hosted`), flag `services:` and `actions/cache` misuse on self-hosted |
| `ci-pr-latency` | The metric to optimise against: wall-clock latency (what you wait for) and machine seconds (what you pay for), reported separately |
| `ci-job-timings` | Report real per-job durations (count, median, p95, max, runner) so tiering uses measurements |
| `ci-cache-health` | Prove the caches work: reads job logs for payload size, primary-key hit rate, and Turborepo remote-cache state, so a cache that is green but never hits cannot hide |
| `turbo-remote-cache/` | Deployable Cloudflare Worker: a Turborepo remote cache backed by R2 |
