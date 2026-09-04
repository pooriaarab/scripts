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
- **Owner label clears it.** `proof-not-applicable`, resolved through the same
  ownership check as `oversized-approved`, skips both the UI attachment and the
  committed media checks. A label the author applies to its own PR does not count.
- **Prose alone is not evidence.** `bun test -> 214 passed` costs an agent
  nothing to write and reads identically whether or not the tests ran. So the
  `How I verified` section must also carry something that happened outside the
  body: a link to the Actions run whose log holds that output
  (`.../actions/runs/<id>`), an attachment, or a `Proof: n/a` reason. This
  **warns** by default and fails when a repo sets `requireAttributableProof:
  true`. It stays a warning in the fleet default because a repo that does not yet
  run its tests in CI would go red on day one, and a standard that turns every
  repo red on its first day gets switched off. Turn it on per repo once the
  repo's own tests run in CI.
- `requireProof: false` turns off every proof check for a repo with no
  user-facing surface.

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
  "proofOverrideLabel": "proof-not-applicable",
  "requireProof": true,
  "requireAttributableProof": false,
  "dependencyManifests": ["**/package.json", "**/composer.json", "**/requirements.txt", "**/requirements-*.txt", "**/go.mod"],
  "destructiveLabel": "human-reviewed",
  "destructiveGlobs": ["**/migrations/**", "**/*.sql", "**/billing/**", "**/*.tf", "**/terraform/**", "**/*secret*", "**/*credential*"],
  "uiGlobs": ["**/*.tsx", "**/*.jsx", "**/*.vue", "**/*.svelte", "**/*.css", "**/*.scss", "**/*.html", "**/components/**", "**/app/**/page.*", "**/pages/**"],
  "uiExcludeGlobs": ["**/*.test.*", "**/*.spec.*", "**/__tests__/**", "**/*.stories.*", "**/pages/api/**"],
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

## What proof looks like, by kind of work

The rule is one sentence: **show the thing a reader cannot otherwise check.** A
reviewer can read your code. A reviewer cannot see your screen, run your query,
open your email in Outlook, or watch your deploy. Proof covers the gap between
what the diff says and what a reader can confirm.

This fleet does not only ship code. A landing page, an ad, a pricing table and a
schema change are all pull requests, and each has a different gap.

| Kind of work | What the reader cannot check | So show |
|---|---|---|
| Product UI | your screen | Before and after, same viewport, same data |
| Landing or marketing page | the rendered page | The preview URL, plus a capture at every breakpoint you touched |
| Design system or component | every state | The component in both themes, and the states you changed |
| Ad or social copy | how the platform renders it | The platform's own preview, captured |
| Email | how a client renders it | The rendered email in one dark and one light client |
| API | what it answers | The request and the response, as a `curl` a reader can run |
| Query, report or analytics | the numbers | The query, its output, and the row count |
| Schema or migration | that it is reversible | Up and down, run against a copy, with the row counts either side |
| Deploy or infrastructure | that it landed | The plan output, or the deployed SHA answering |
| Backend logic | that it was broken before | The test that fails without the change and passes with it |
| Docs prose | nothing — they can read it | The diff. `Proof: n/a` is right here |

Three things this table is saying that are easy to miss:

- **A screenshot of the result is not proof of a change.** One image shows what
  the screen looks like now. It cannot show that your diff is why. That is the
  whole reason the checker warns on exactly one attachment.
- **For work that is not code, the artifact is the deliverable.** An ad's render
  is not evidence *about* the work, it *is* the work. Reviewing the copy in a
  diff and never seeing it rendered is reviewing half of it.
- **`Proof: n/a` is a real answer, and it is rare.** A type-level refactor, a
  comment fix, a prose edit: nothing to show. Anything a person will see, click,
  read, or be billed for has a capture. When `Proof: n/a` becomes routine in a
  repo, the honest fix is `requireProof: false` in that repo's config, not a
  habit of writing a reason nobody reads.

## A new dependency states its case

A dependency is the cheapest line an agent can write and the most expensive one
to remove. Nobody reads the licence, nobody measures what it costs to ship, and
by the time either matters the package has thirty callers.

The checker reads the manifests in `dependencyManifests` and pulls out names the
diff *adds* — a version bump edits a line that already exists, so it does not
count. Each new name needs a line in the body:

    Dependency: <name> — <licence>, <size it adds>, <why nothing already here does this>

At least 30 characters after the dash. `Dependency: lodash — needed` fails.

The checker does not verify the licence or the size, and that is the design
rather than a gap. Fetching either means a network call inside a check, so the
check goes red on a registry outage and everyone learns to re-run it. Writing the
answer down is enough to change the outcome: a stated licence is a claim the
review council reads and a reviewer can catch, while a package added in silence
is not a claim at all.

Manifests understood today: `package.json` and `composer.json` (a key whose value
looks like a version range), `go.mod`, and `requirements*.txt`. `Cargo.toml` and
`Gemfile` are not read yet — a repo using them sees no dependency check rather
than a wrong one. Set `dependencyManifests: []` to opt out.

GitHub omits the patch for a manifest diff too large to inline. That is exactly
the diff most likely to smuggle in a dependency unseen, so a matched manifest
with real changes and no patch fails the check rather than passing silently —
state what was added, or split the change so it can be read.

## Destructive changes stop for a person

A schema migration, a billing path, an infrastructure plan and a credential file
share one property: getting them wrong is not a defect you fix in the next pull
request. No amount of reading the diff tells you a migration is reversible or
that a price change is the intended one.

So the checker does not try to judge. A pull request touching `destructiveGlobs`
fails until the repo owner applies `human-reviewed`, resolved through the same
ownership check as the other two labels — an agent cannot clear its own stop.

The default list is deliberately short:

```
**/migrations/**   **/*.sql   **/billing/**   **/*.tf   **/terraform/**
**/*secret*   **/*credential*
```

Every glob costs a human decision on every pull request that matches it. A list
long enough to catch everything trains the owner to apply the label without
reading, which is worse than having no gate. Add to it per repo, from real
incidents, never for comfort. Set it to `[]` to opt out.

`.github/workflows/**` is *not* in the default list, and the omission is a
judgement call rather than an oversight: in a fleet where a rollout writes a
workflow into every repo, including it would demand a label on every adoption
pull request and burn the owner's attention on the one change they already
decided to make. A repo whose workflows hold deploy credentials should add it.

**The gate assumes nothing merges without a human.** It fails a check; it cannot
stop a merge. On a repo where an unattended process merges with the account
token, this label is a suggestion. Fix the merger first, or the gate is
decoration.

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
