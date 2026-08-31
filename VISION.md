# Vision — scripts

## What this is

`scripts` is the automation layer of one developer's agent workspace. Its
scripts diagnose CI speed and cost, hold every pull request in the fleet to one
PR standard, keep the ascii.dev Boxes that run agent work provisioned, cheap
and bounded, and print the one message a day that needs a person. Markdown
playbooks beside the scripts record how to publish to third-party portals and
the traps found while running that estate.

## Who it is for

One developer: the owner, pooriaarab, who runs coding agents across personal
repositories, a self-hosted runner fleet, and per-repo ascii.dev Boxes. The
single-user scope is deliberate. `install-pr-hooks` writes hooks into local
pooriaarab checkouts only, and the launchd plists carry the owner's name. A
second, passive audience is every fleet repo that adopts
`.github/pr-standards.json`; the checker inspects those repos from here.

## What good looks like

- The four `ci-*` scripts, run in order, name the job that sets wall clock, the
  caches that restore nothing, and the jobs sitting on a runner tier that cannot
  run them, before anyone optimises.
- `fleet-digest` prints one message a day, and prints `Nothing needs you.` when
  a day needs nobody.
- A pull request with the wrong branch pattern, over 500 counted lines, or more
  than one `Closes #` fails the `pr-standards` check before it merges.
- `box-reap` reports what each Box costs and stops the unused ones, hourly,
  under launchd.
- `agent-defect-rate` prints each agent's revert and hot-fix rate with the
  denominator beside it.

## Explicitly not this

- A new reusable agent skill. The README sends readers to the `skills` repo for
  the `ci-speed-diagnosis` skill; this repo carries the scripts and links out.
- A CLI for an ad-platform API. The README assigns those to the `clis` repo.
- Slash commands, refined prompts, or changes to the portable `.agents` hub.
  The README assigns those to the `commands`, `prompts` and `agents` repos.
- A multi-user release of this tooling. The scripts name the owner's checkouts,
  plists and agent roster, and the checker ships as two fetched files, not as
  an installable package. <!-- CHECK -->
- Product source code. The README names `content-rabbit` only as a repo the
  checker inspects; no application code lives here.

## How it pays for itself

No one sells this repo. It pays the owner back in time and machine spend. The
digest replaces hand-checking many repositories. The CI scripts point the
diagnosis at the job that sets wall clock and at caches that actually miss, so
money does not go to jobs that cannot change the wait. The Box reaper stops
Boxes that nothing else will stop. The defect-rate script says which agents
deserve review time. The repo enforces its own standard: a test suite runs on
every pull request, and every failing group reports in one run.

## The current bet

The bet, as of the head commit d548c55: checks and one daily digest can hold
every agent-written change in the fleet to the PR standard (one issue, one PR,
one concern, under 500 counted lines) in place of review hours. <!-- CHECK: no
date exists in the evidence; the bet is read from the latest commit subjects
(d548c55, 0efe915, 33c190d, b03d3bc, 17a3a4b). -->
