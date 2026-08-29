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
| `prefix` | 2–4 lowercase letters. One per repo, fixed. Read from `.github/pr-standards.json`. |
| `issue` | A GitHub issue number that **exists and is open**. No issue, no branch. No `0`, and no leading zeros, so one issue has exactly one branch name. |
| `slug` | `[a-z0-9]+(-[a-z0-9]+)*`, 3–48 characters. Describes the change, not the file. |

Full pattern: `^[a-z]{2,4}-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$`

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

Each repo carries `.github/pr-standards.json`. The rollout writes it; the check
reads it; nothing fetches a central registry at check time.

```json
{
  "prefix": "cr",
  "requireIssue": true,
  "allowChoreEscape": false,
  "maxLines": 500,
  "maxFiles": 40,
  "maxTopLevelDirs": 3,
  "minBodyChars": 120,
  "overrideLabel": "oversized-approved",
  "exemptBranches": ["main", "release", "refactor", "gh-pages"],
  "excludeGlobs": ["..."]
}
```

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
