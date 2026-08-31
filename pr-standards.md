# PR standards for an agent fleet

Agents generate pull requests faster than anyone reviews them. Generation costs
almost nothing now; review costs exactly what it always did. That gap is why a
fleet drifts, an agent opens a 20,000-line PR against no agreed scope, and the
only thing standing between it and `main` is your attention.

This document is the standard. `pr-standards` is the program that enforces it.
One engine, four layers: an agent hook, a git hook, a CI check, and a review lens.

## The rule

**One issue. One PR. One concern. Under 500 lines.**

Everything below is that sentence, made checkable.

### Branch name

    <prefix>-<issue>-<slug>

    cr-142-fix-onboarding-drop-off
    pt-7-add-safari-extension-build
    rts-91-retry-stripe-webhooks

| Part | Rule |
|---|---|
| `prefix` | 2–4 lowercase letters. One per repo, fixed. Read from repo config, then the bundled fleet registry, then derived from the repo name. |
| `issue` | A GitHub issue number that **exists and is open**. No issue, no branch. No `0`, and no leading zeros, so one issue has exactly one branch name. |
| `slug` | `[a-z0-9]+(-[a-z0-9]+)*`, 3–48 characters. Describes the change, not the file. |

Full pattern: `^[a-z]{2,4}-[1-9][0-9]*-[a-z0-9]+(-[a-z0-9]+)*$`

Exempt, never checked: `main`, `release`, `refactor`, `release/*`, `gh-pages`,
`dependabot/*`, `renovate/*`.

The issue number is the join key. It ties the branch, the title, the body, and
the merged commit to one agreed piece of work. When this fleet moves to Linear,
only the source of the number changes.

### PR title

    [CR-142] Fix onboarding drop-off on step three

- Tag is the uppercase prefix and the same issue number as the branch.
- Subject after the tag: imperative mood, 10–50 characters, no trailing period,
  starts with a capital letter.
- Rejected openers, because they are not imperative: `Added`, `Fixed`, `Updated`,
  `Removed`, `Changed`, `Refactored`, `Implemented`, and any `-ing` first word.
- No emoji. No conventional-commit prefix, the tag already carries the scope.

### PR description

Four things, all required:

    Closes #142

    ## What
    One to three sentences. What changed, in plain words.

    ## Why
    The problem from issue #142, and why this is the fix.

    ## How I verified
    bun test        -> 214 passed
    bun run build   -> clean
    Manually walked steps 1-4 of onboarding in staging.

    Assisted-by: claude-personal:claude-opus-5

- **Exactly one** closing reference, matching the branch issue. Two closing
  references means two concerns, which means two PRs.

  Count all nine keywords GitHub honours, not just the one in the example:
  `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
  `resolved`. Each of them also works with a colon (`Closes: #10`) and in the
  cross-repo `owner/name#100` form. A checker that knows only `Closes #N` lets
  `Closes #1` plus `Fixes: #2` through, which is two concerns wearing one coat.
  A cross-repo reference counts toward the one-reference rule, because it is
  still a second thing the PR closes, but it can never satisfy the branch issue.
  A reference inside an HTML comment does not count, so an unedited template
  cannot trip it.
- `## How I verified` must name a command and its result. `N/A`, `TODO`, `tested
  locally`, and an unedited template comment all fail.
- Body under 120 characters fails. A description that only restates the diff is
  not a description.
- The body must contain an `Assisted-by: <agent>:<model>` line. It discloses which
  fleet member wrote the change. The Linux kernel uses this convention for the same
  reason: so you can tell, later, which agent produced which class of defect.
  Convention puts it last. The check accepts it anywhere in the body rather than
  pretending to enforce a position it does not.

### Commits

No commit carries an AI attribution trailer. Not `Co-Authored-By: Claude`, not
`Co-authored-by: Codex`, not `Generated with [Claude Code]`, and the same for
Gemini, Kimi, Muse, pi, Copilot, Cursor and the rest. The commits should read as
the author's own work, because that is what they are: a person decided what to
build, reviewed it, and is answerable for it.

Two deliberate exceptions:

- `Co-authored-by: vibecodereview` stays. That is the review bot recording a fix
  it actually made, which is a real author rather than a model taking credit.
- `Assisted-by: <agent>:<model>` in the pull request **body** is required, not
  banned. Disclosure of which fleet member produced a change is the thing that
  lets you tell later which one keeps producing defects. Credit in every commit
  message is not: an `Assisted-by` trailer in a commit fails the check no
  matter which agent it names, because the commit is the wrong place for it
  regardless.

The banned list is `bannedCommitTrailers` in the config, so a repo can add an
agent without editing the checker.

This applies to new pull requests. Existing history is left alone: rewriting it
would change every commit id in eight active repos to remove a cosmetic line.

### Size and atomicity

| Cap | Limit | On breach |
|---|---|---|
| Net counted lines (`+` and `-`) | more than **500** | fail |
| Counted files changed | more than **40** | fail |
| Closing issue references | not exactly **1** | fail |
| Top-level directories touched | more than 3 | warn |

The boundaries are inclusive: 500 counted lines passes, 501 fails. "Under 500" in
prose and a bare `500` in a table are not the same rule, so the table is the rule.

Not counted, an agent should never be penalised for a lockfile it did not write:

    **/*.lock  package-lock.json  bun.lockb  pnpm-lock.yaml  yarn.lock  Cargo.lock
    dist/**  build/**  .next/**  out/**  vendor/**  **/generated/**
    **/__snapshots__/**  **/*.snap  **/*.generated.*  **/migrations/**
    **/*.min.js  **/*.map
    **/*.{svg,png,jpg,jpeg,gif,webp,ico,woff,woff2,ttf,otf,mp4,pdf,zip}

**500 is a design constraint, not a nuisance.** It is roughly one reviewable
sitting. An agent that must stay under it decomposes the work before it writes,
which is the behaviour we actually want. If a change genuinely cannot be split,
that is a fact worth stating out loud, so the only way past the cap is the
`oversized-approved` label, applied by the repo owner. An agent cannot clear its
own PR.

**Atomic means one concern.** The mechanical proxies above catch the obvious
cases. Whether a PR really does one thing is a judgement, and that judgement
belongs to the review council, see the scope lens in `vibecodereview`.

## Configuration

Each repo may carry `.github/pr-standards.json`. The rollout writes it, and the
checker uses its prefix first. Without that prefix, the checker reads the
bundled `repo-prefixes.json` registry, then derives a prefix for a new repo.

**The file states what the repo decides, and nothing else.** A fresh rollout
decides one thing:

```json
{
  "prefix": "cr"
}
```

Everything else stays at the default, in the checker, where fixing it once fixes
it for every repo. A copied default is not a no-op: the file is merged over the
defaults, so a repo that restates all of them is pinned to the values of the day
it was rolled out and a later fix never reaches it. That is the opposite of what
one central checker is for, and it is what the moving `pr-standards-v1` tag exists
to avoid.

Add a key only to record a decision that differs, and the diff then says what the
repo chose:

```json
{
  "prefix": "cr",
  "maxLines": 900,
  "allowChoreEscape": true
}
```

The full set of keys and their defaults is `DEFAULT_CONFIG` in `pr-standards.mjs`.

`allowChoreEscape` is off. Turn it on and a `chore/<slug>` branch skips the issue
requirement, which helps if dependency bumps and CI fixes start costing more in
issue bookkeeping than they save. It is a knob so the decision stays visible.

**It skips the issue requirement and nothing else.** A chore branch still has to
satisfy every title and body rule: imperative subject, the three sections, the
minimum length, the `Assisted-by` line. It must also carry no closing reference,
because a change that closes an issue is not a chore and belongs on a numbered
branch. The obvious implementation gets this wrong. Written as "there is no issue
number, so skip the checks that need one", the knob quietly disables the title and
body rules too, and becomes a way to opt out of the whole standard.

## Generated file drift

A hand-edit to a generated file is a defect, not a shortcut. The edit reads
correctly in review, and from then on the file disagrees with its generator: the
next regeneration either reverts the change or keeps it and drifts further.
Reading the diff cannot catch this. Running the generator can.

The `generated-drift` workflow runs each command in `generators` on every pull
request, then fails when `git status --porcelain` reports anything. The log
carries the offending paths and `git diff --stat`, and the job leaves one comment
naming the drifted files. It updates that comment on re-runs rather than posting
a second one.

Two keys in `.github/pr-standards.json` configure it:

- `generators` — shell commands, in order, for example
  `["bun run db:generate", "bun run build:types"]`. Absent or empty means the job
  skips and passes, so a repo with no generators stays green.
- `generatorSetup` — one optional command that runs first, for example
  `bun install --frozen-lockfile`.

`pr-standards-templates/generated-drift.test.sh` runs the embedded check against a
throwaway git repo. It exists because the first version read its config through an
unexported shell variable: every lookup raised, every raise was swallowed, and the
job passed on every repo without running a generator. A check that silently never
runs is worse than no check, because its green tick is a lie.

Install it with `pr-standards-rollout --with-generated-drift`.

## The four layers

Local layers exist for speed. CI is the authority. Neither replaces the other.

| Layer | Runs | Catches | Bypassable |
|---|---|---|---|
| Claude Code `PreToolUse` hook | at tool-call time | a bad branch before it exists | by another agent |
| `pre-push` git hook | before the push | a bad branch before GitHub sees it | `--no-verify` |
| `pr-standards.yml` in CI | on every PR | everything, including size and body | only by ignoring red |
| `vibecodereview` scope lens | on every PR | non-atomic and off-scope work | by ignoring the review |

The table describes what each layer catches once installed. A layer not rolled
out to a repo catches nothing there, so read it as the design rather than as the
state of any particular repo.

There is a fifth layer, and whether you can have it depends on plan AND
visibility, not plan alone:

| Repo | Rulesets and required checks on GitHub Free |
|---|---|
| Public | Available |
| Private, personal account | Needs GitHub Pro |
| Private, organization | Needs GitHub Team or Enterprise |

So on this account the public repos can be gated and the private ones cannot.
Where nothing can be required, red CI is a signal rather than a gate, and the
local layers carry more weight, though `--no-verify` still skips the git hook.
They are early feedback, not a boundary.

Caution: do not add `pr-standards` as a required status check on a repo before
the workflow is installed there. Requiring a check the repo never runs blocks
every pull request in that repo, permanently.

## The two local layers

CI is the authority, but it is also the slowest feedback. Two local layers catch a
bad branch before GitHub ever sees it. Neither is a boundary — `--no-verify` skips
the git hook, and another agent's harness never loaded the Claude Code hook — so
treat them as early feedback, not enforcement.

- `install-pr-hooks --apply` puts the `pre-push` hook in every eligible checkout.
- `hooks/pr-standards-guard.sh` is the Claude Code `PreToolUse` hook, and the
  earliest feedback available: it rejects a branch name before the branch exists.
  Register it in `.claude/settings.json` under `hooks.PreToolUse` with matcher
  `Bash`:

  ```json
  { "type": "command", "command": "<path>/hooks/pr-standards-guard.sh" }
  ```

  It checks only branch *creation*. Deleting or renaming a branch is how you
  recover from a bad name, so guarding those would trap you in one. It lets a call
  through whenever it cannot parse its own input, because blocking on its own bug
  is worse than the branch name it guards against.

To install the standard itself in a repo — the config, the PR template and the
workflow — use `pr-standards-rollout`.

## Usage

```bash
pr-standards branch                      # validate the current branch name
pr-standards branch cr-142-fix-onboard   # validate a specific name
pr-standards precheck --branch X --title Y   # for the agent hook; no network
pr-standards pr --repo pooriaarab/content-rabbit --number 88
pr-standards pr --repo pooriaarab/content-rabbit --number 88 --json   # machine-readable
```

Exit 0 clean, exit 1 on any failure, exit 2 on a configuration problem.
Warnings never change the exit code.
