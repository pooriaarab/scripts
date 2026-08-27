# Self-hosted runner fleet

Turn spare always-on machines into GitHub Actions runners for private repositories. One
runner service per repository, because a personal GitHub account has no account-wide
runner.

## Why

Measured on one host (i9-10900, 128 GB RAM), fifteen private repositories moved over in a
day:

| | |
|---|---|
| CI on a hosted runner | 1–4 min queue, then the run |
| CI on the fleet host | no queue, and roughly half the wall clock |
| Actions minutes consumed | none |
| Marginal cost | the electricity of a box that was already on |

The install is the easy part. What actually decides whether this works is (a) which jobs
you move and (b) three host details that make jobs fail on your machine and nowhere else.

## Which jobs to move

| Move | Keep hosted |
|---|---|
| build, lint, typecheck, unit tests, E2E | deploy, release, publish, production smoke |
| dry-run / plan / simulation steps | anything needing a macOS or Windows image |
| AI review jobs (secrets are injected normally) | workflows that run a prompt from comment text |
| formatting bots that push to a PR branch | `gitleaks-action` SARIF uploads (see below) |

Two rules that are easy to get wrong:

- **Never copy secret values to the host.** GitHub injects repository secrets into trusted
  self-hosted jobs, so AI review keeps working untouched.
- **A `@mention`-triggered workflow executes attacker-suppliable text.** Keep it hosted
  even though it looks like just another AI job.

## Use

```sh
export RUNNER_SSH_TARGET=user@100.x.y.z    # Tailscale address of the host
export RUNNER_SSH_KEY=~/.ssh/that-host
export RUNNER_NAME=STUDIO-M2               # runner name shown on GitHub
export RUNNER_LABEL=studio-ci              # label your workflows will target
export RUNNER_WSL_DISTRO=Ubuntu            # Windows host only; omit on Linux

./add-repo.sh prepare-host
./add-repo.sh register OWNER/REPO          # first service
./add-repo.sh register OWNER/REPO 2        # second service, so its jobs run in parallel
./add-repo.sh status OWNER/REPO
```

Then point the reviewed jobs at the label:

```yaml
runs-on: [self-hosted, linux, studio-ci]
```

## The three host details nobody documents

`prepare-host` applies all three. Each was found by a job that passed on GitHub and failed
on the host:

1. **Passwordless sudo for the service account.** Hosted images have it, so workflows use
   it freely — `sudo apt-get install` for build dependencies, and `playwright install
   --with-deps`, which elevates by itself. Without it: `sudo: a password is required`.
2. **A separate `HOME` per runner service.** Every service usually runs as the same user,
   so two concurrent jobs share `~/.bun`, `~/.cache`, `~/setup-pnpm`. Symptom:
   `bun install` dies with `/home/runner/.bun/bin/bun: Text file busy`, or a build picks up
   another repository's tool version. Fix: a systemd drop-in with
   `Environment=HOME=<runner-dir>/home`.
3. **A toolchain as new as the hosted image.** A host on Node 20 breaks every `wrangler`
   step, because `wrangler` requires Node 22 while hosted images ship 24.

## Windows hosts: WSL will stop and kill your jobs

Run the runner inside WSL2. A stopped WSL kills the running job, and the symptoms do not
say "WSL":

| Symptom | Cause |
|---|---|
| Steps `null` after `Checkout` succeeded | WSL went down mid-job |
| Run stuck in `queued` while the runner looks idle | no WSL, no listener |
| Runner API says `offline busy=true` | GitHub still holds the dead session |
| `A session for this runner already exists` in the journal | restarted runner cannot reclaim it yet |

Two holders are needed, not one:

- `%USERPROFILE%\.wslconfig` → `[wsl2]` / `vmIdleTimeout=-1` (needs `wsl.exe --shutdown`
  to apply, so do it while the fleet is idle).
- A scheduled task holding `wsl.exe -d <distro> --user <user> -- bash -lc "exec sleep
  infinity"`, with an **at-startup** trigger and principal `LogonType=S4U`. The obvious
  `LogonType=Interactive` never fires on a headless desktop — `quser` returns nothing on a
  machine nobody logs into, and that is the normal state for a CI host.

Native Windows OpenSSH often uses PowerShell as its default shell, so remote commands are
PowerShell. Send bash as base64 and decode on the far side instead of fighting quoting.

## One job that cannot move

`gitleaks-action@v2` scans fine, then fails uploading `results.sarif`: it resolves the
artifact root from the runner's home, which is not a parent of a workspace under
`/opt/actions-runner`. Leave it hosted and comment why in the workflow.

## Remote-dev tools are a separate fight

A synced remote-dev tool (Crabbox and similar) verifies the workspace it just synced by
fetching the target commit from the forge **on the host**, with Git credential helpers
neutralized (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `-c credential.helper=`). On a
private repository that fails even though a plain `git fetch` on the host succeeds. SSH
transport is unaffected by the neutralization, so the fix is an SSH key on the host — an
account-level key covers every repository, a deploy key covers one and needs a host alias
and a URL rewrite per repository.
