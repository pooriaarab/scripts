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
  locally`, and an unedited template comment all fail. A change with no visible
  surface to click through or screenshot still needs a command and its result;
  add `Proof: n/a — <reason>` alongside it to say why there is nothing further
  to show. The reason is not optional, and the hatch never waives the command
  and its result — only the extra, visible proof.
- Body under 120 characters fails. A description that only restates the diff is
  not a description.
- The body must contain an `Assisted-by: <agent>:<model>` line. It discloses which
  fleet member wrote the change. The Linux kernel uses this convention for the same
  reason: so you can tell, later, which agent produced which class of defect.
  Convention puts it last. The check accepts it anywhere in the body rather than
  pretending to enforce a position it does not.

#### Proof of work

`## How I verified` must also carry proof that the change worked, not just the
name of a command. An agent can write "tested locally" for free; a screenshot
or a real command output costs work, so it is the part worth checking.

| Work class | Proof |
|---|---|
| UI (a user can see it) | before and after screenshots, or a short video of the flow |
| Backend, API, CLI | the command and its real output |
| Bug fix | the test failing before, passing after |
| Performance | the numbers before and after |
| Infrastructure, CI | a link to the green run |
| Copy, docs, marketing | a screenshot of the rendered page, or the preview URL |

Media goes to GitHub user-attachments. Media never goes into a commit. A commit
carries the change; the pull request carries the evidence.

The checker enforces only what it can cheaply and mechanically:

- **UI diff needs an attachment.** If any changed file matches `uiGlobs` and is not
  excluded by `uiExcludeGlobs`, the body must contain at least one
  `https://github.com/user-attachments/assets/<id>` URL. Zero attachments and no
  `Proof: n/a` line fails; exactly one attachment warns ("a visual change wants
  before and after"); two or more passes. For a diff with no UI files, the
  existing command-and-result rule already stands and no attachments are required.
- **Committed proof media fails.** A file added by the diff whose extension is
  `png`, `jpg`, `jpeg`, `gif`, `webp`, `mp4`, `mov`, or `webm` and whose path
  matches `screenshot*/**`, `**/screenshots/**`, `proof*/**`, `**/*before*`,
  `**/*after*`, `**/*demo-recording*`, or sits in the repo root is rejected: it
  belongs in user-attachments. A screenshot committed to a repo stays in its
  history forever, for a picture nobody opens twice. Media anywhere else (`public/**`, `**/assets/**`, and every other path) is a real
  asset and is not flagged.
- **No label clears it.** There is no `proof-not-applicable`. The size cap's
  override label was removed for the reason that an agent can apply its own
  label, and a proof requirement an agent can waive is not a requirement.
- `requireProof: false` turns off both proof checks for a repo with no
  user-facing surface. That is a config decision: it lives in the repo, it shows
  up in a diff, and it is reviewed like any other change.

Escape hatch, when proof truly does not apply:

    Proof: n/a — <reason, at least 20 characters>

The checker accepts it; the review council judges whether the reason holds. An
agent cannot clear its own proof requirement with "not applicable".

How an agent captures and uploads proof:

```bash
curl -sS -X POST \
  "https://uploads.github.com/user-attachments/assets?name=<file>&content_type=<mime>&repository_id=$(gh api repos/<owner>/<repo> --jq .id)" \
  -H "Authorization: Bearer $GITHUB_ATTACHMENTS_TOKEN" \
  -H "Accept: application/json" \
  -H "Content-Type: <mime>" \
  --data-binary @<file>
```

- If `GITHUB_ATTACHMENTS_TOKEN` is unset, skip the upload and say so in the body.
  Do not commit the file as a fallback.
- Images embed as `![alt](url)`. A video goes on its own line as a bare URL.
- Supported types: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `video/mp4`.
  Convert first when needed: `ffmpeg -i in.webm -c:v libx264 -pix_fmt yuv420p out.mp4`
- Capture during reproduction and again during verification, so before and after
  come from the same run.
- When a later push changes the UI on screen, recapture and replace the embed.
  Keep every embed that is still accurate; never drop one while rewriting a body.
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
which is the behaviour we actually want.

**The cap has no escape.** There was one — an owner-applied `oversized-approved`
label — and it is gone. Every escape from a design constraint becomes the path:
an agent told it may ask for a label asks for the label instead of decomposing
the work, which is the one thing the cap exists to force. A change that seems
unsplittable almost always splits once you accept that it has to.

One escape remains, and it is deliberately awkward: a person merges past a red
check. That takes an act by a human on a named pull request. It cannot be
requested in a body, and it leaves a record.

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

## VISION.md

The checker asks whether a pull request is one thing. The review council asks
whether it is well built. Neither can ask whether the change belongs in this repo
at all, because nothing in the repo says what the repo is for. A change can pass
every check, do exactly one thing, carry real proof, and still be the wrong change.

`VISION.md` at the repo root closes that gap. The council reads it when the repo
has one. `pr-standards-templates/VISION.md` is the template.

Six sections, and only one of them does the work:

| Section | What it answers |
|---|---|
| What this is | The repo in a user's words |
| Who it is for | One named reader, never "everyone" |
| What good looks like | Three to five observable outcomes |
| **Explicitly not this** | **Three to five changes that would be well built and still wrong here** |
| How it pays for itself | The business model, or whose time it saves |
| The current bet | One sentence with a date |

Write "Explicitly not this" last, and write it from requests you have already
turned down. Every other section tells a reviewer what to accept. Only that one
tells it what to reject, and a vision that rejects nothing changes no review.

Two failures to avoid:

- **A template left as prompts.** The council judges against whatever text is
  there. Placeholder prose reads as a vision that permits everything, which is
  worse than no file, because the absent file at least makes the council fall
  back on the diff and the issue.
- **A stale bet.** "The current bet" carries a date so drift is visible. A repo
  whose bet has not moved in a year is either finished or abandoned, and the
  vision should say which.

## Usage

```bash
pr-standards branch                      # validate the current branch name
pr-standards branch cr-142-fix-onboard   # validate a specific name
pr-standards precheck --branch X --title Y   # for the agent hook; no network
pr-standards pr --repo pooriaarab/content-rabbit --number 88
pr-standards pr --repo pooriaarab/content-rabbit --number 88 --json   # machine-readable
pr-standards drift                       # check the managed AGENTS.md block and PR template for drift
```

Exit 0 clean, exit 1 on any failure, exit 2 on a configuration problem.
Warnings never change the exit code.
