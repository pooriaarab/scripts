# ship-sync failure modes

`ship-sync` measures the commits that each branch lacks.
When production only trails main, it opens a PR from main to production.
It creates no sync branch and pushes nothing.
The PR body records the comparison and the merge-tree exit code.

When production has unique commits, the tool builds a branch with main's tree.
An ours-merge records production as a second parent, so the PR merges cleanly.
The tool prints which path it takes and why. It never switches paths after a failure.
It never merges the PR.

A diverged release over 500 counted lines still fails the cap.
No label clears the cap. The `oversized-approved` label no longer exists.
The promotion exemption requires the repository's own default branch as the head.

This file lists every way the tool can fail. The tests in
`ship-sync.test.sh` cover each row marked "tested".

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | `--repo`, `--prefix`, or `--assisted-by` is missing. The tool cannot know which agent and model ran it, so it does not guess. | Exit 1 with usage. | yes |
| 2 | Neither `--issue` nor `--open` is given, so there is no issue number for the branch. | Exit 1. | yes |
| 3 | The checkout has uncommitted changes. | Exit 1 before any change. | yes |
| 4 | The production branch does not exist on the remote. | Exit 1. Say to create it first. | yes |
| 5 | `main` and production already have the same tree. | Print that there is nothing to ship. Exit 0. Create no branch. | yes |
| 6 | The branch name contains the word "release". Fleet pre-push hooks refuse such names. | Exit 1 before any change. | yes |
| 7 | A plain `main` to production merge conflicts after a squash. | The ours-merge records production as a parent, so the PR merges with no conflict. | yes |
| 8 | The branch tree differs from `main`. | Exit 1. Push nothing. | no, guard only |
| 9 | The PR body fails the checker: `## What` too long, proof lines not in `` `cmd` -> result `` form, a missing `Closes #`, or a missing `Assisted-by`. | The test runs the checker's own `validateBody` on the output. | yes |
| 10 | Without `--open`, the tool pushes or calls GitHub. | Without `--open`, write the body. Build a local branch only for divergence. | yes |
| 11 | With `--open`, issue creation fails. | Exit 1. Push nothing. | yes |
| 12 | Anything asks the tool to merge. | There is no merge path. A person merges after review. | yes |
| 13 | Release only trails main, but the PR head is a sync branch. | Use main as head. Create no branch and push nothing. | yes |
| 14 | A direct promotion lacks comparison or merge evidence. | Record behind/ahead counts and the merge-tree exit code. | yes |
| 15 | A local main is stale. | Use origin/main for evidence and the reported SHA. Leave local refs unchanged. | yes |
| 16 | The operator cannot tell which path ran. | Print the path and unique commit counts. | yes |
| 17 | An issue is supplied for a direct promotion. | Reuse it without creating another issue. | yes |
| 18 | The direct merge check fails. | Stop before issue creation. Never switch paths. | no, guard only |
