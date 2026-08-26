# Remote agent dev box

One always-on Linux box that holds the repos, the worktrees and the agent CLIs,
driven from the laptop (or a phone) through Superset and T3 Code. The laptop
becomes a thin client.

## Why

Measured on the laptop, 2026-08-26:

| | |
|---|---|
| One Content Rabbit checkout | 9.7 GB (6.9 GB `node_modules`, 1.7 GB build caches, 640 MB `.git`) |
| 48 live worktrees of that one repo | **86 GB** |
| Laptop disk free | **89 GB of 926 GB** |

One repo's worktrees already fill the disk, and there are 114 repos. A remote box
with a real disk removes the ceiling and keeps sessions alive when the laptop
sleeps.

This is also why a serverless sandbox does not work here. Cloudflare Containers
cap at 4 vCPU / 12 GiB / **20 GB disk**, and the disk is wiped on every wake — it
cannot hold two worktrees, let alone forty-eight.

## Sizing

Next/OpenNext builds run with `--max-old-space-size=8192`, so budget ~12 GB
resident per concurrent build.

- **RAM:** 64 GB (three parallel builds plus a handful of agent CLIs)
- **Disk:** 500 GB+ NVMe (86 GB is one repo)
- **CPU:** 8+ cores; `bun install`, turbo and `tsc` all fan out

A Hetzner **AX41-NVMe** (Ryzen 5 3600, 64 GB, 2×512 GB NVMe, ~€49/mo, less on the
[auction](https://www.hetzner.com/sb/)) fits. Hetzner's cloud line got 107–204%
more expensive for x86 in 2026, so a dedicated root server is now better value
than CCX. If you would rather stay on cloud, ARM was barely touched — CAX41
(16 vCPU, 32 GB, 320 GB) is ~€32/mo, but verify arm64 builds exist for kimi,
muse and pi before committing.

## Phase 1 — provision

Ubuntu 24.04, your SSH key, no password login. Note the IP.

## Phase 2 — bootstrap

```bash
scp scripts/agent-devbox/bootstrap.sh box:
ssh box 'bash bootstrap.sh'
```

Installs the base toolchain, Node, Bun, `gh`, a 16 GB swapfile, ufw, and the
agent CLIs that publish Linux packages: Claude Code, Codex, Gemini CLI, Superset.

### Phase 2b — the three that need hands

`kimi`, `muse` and `pi` ship their own installers and I have not confirmed a
Linux build for each. Install them by hand and re-run the script's verify block.
The box is useful without them — Claude, Codex and Gemini cover the roster.

## Phase 3 — log the agents in

Every agent CLI uses an OAuth flow that redirects to `localhost` **on the box**,
where there is no browser. Forward the callback ports to the laptop first, then
open the printed URL in the laptop browser:

```bash
ssh -L 1455:localhost:1455 -L 1456:localhost:1456 -L 8976:localhost:8976 box
# then, inside that session:
gh auth login
claude-personal          # /login
CODEX_HOME=~/.codex-personal codex login
GEMINI_CLI_HOME=~/.gemini-personal gemini
```

Keep one config dir per identity, exactly as on the laptop. `~/.agentrc` (written
by the bootstrap) sets `CODEX_HOME` and `GEMINI_CLI_HOME` and defines
`claude-personal` / `claude-personal-1`.

**Only personal accounts on this box.** No work profile, no Mozilla source. The
box is a third-party host and the work/personal split has to survive the move.

**Do not bake credentials into an image.** If this ever becomes a template, mount
the tokens at boot from a secret store. Baked tokens sit in an image layer that
every clone of the box shares.

## Phase 4 — Superset remote workspaces

Superset has first-class remote hosts, so no VPN is needed. Its relay routes
laptop → box.

On the box (headless, so use an API key from Settings → API Keys — `superset auth
login` wants a browser):

```bash
export SUPERSET_API_KEY=sk_live_...     # put it in ~/.agentrc to persist
superset start --daemon --org <org-slug>
superset status --org <org-slug>
```

On the Mac: same org → **Workspaces** → **Device** filter → pick the box under
"Other devices".

Known limitation: dev-server ports are not forwarded to the laptop yet, so
`localhost:PORT` only resolves on the box. Tunnel per port when you need a
browser on it:

```bash
ssh -L 1355:localhost:1355 box     # portless / bun run dev:worktree
```

Run `/superset:setup` once per repo you fan out on, so `.superset/config.json`
boots each worktree green.

## Phase 5 — T3 Code remote

T3 needs a network path, so this is the part that wants Tailscale.

```bash
# both machines
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up

# on the box
npx t3@latest serve --tailscale-serve
sudo npx t3@latest service        # always-on; systemd, so this works here
```

`t3 service` refuses to install on macOS but is supported on Linux + systemd —
moving to a Linux box is what makes always-on T3 possible.

Then in the T3 client, add one Claude provider **per config dir** (set the
`CLAUDE_CONFIG_DIR path` field, not `HOME`, not launch args):

| Provider name | CLAUDE_CONFIG_DIR |
|---|---|
| Claude Personal | `~/.claude-personal` |
| Claude Personal 1 | `~/.claude-personal-1` |

A thread is pinned to its config dir at start, so pick the subscription with
headroom up front. Set **Auto-compact after** to ~300000 tokens.

T3 worktrees have no setup hook, so a fresh thread will not install deps by
itself — the thread's agent has to run the install. Repo-root `CLAUDE.md` /
`AGENTS.md` and `.claude/skills` do load.

## Phase 6 — disk hygiene

The box has more disk, not infinite disk. 48 worktrees × 9.7 GB is 86 GB for one
repo. Prune merged ones on a schedule:

```bash
git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r w; do
  b=$(git -C "$w" branch --show-current) || continue
  [ -z "$b" ] && continue
  git branch --merged origin/main | grep -qx "  $b" && echo "stale: $w ($b)"
done
```

Review the list, then `git worktree remove` the ones you are done with.
