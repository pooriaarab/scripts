# ship-sync failure modes

A repo that promotes `main` to a production branch with squash merges loses
the shared history after the first promotion. The second `main` to
production PR then conflicts on every file both sides touched. `ship-sync`
builds a branch whose tree is exactly `main`, with the production branch
recorded as a second parent by an ours-merge, so the PR merges cleanly. It
writes a PR body that passes the pr-standards checker. It never merges.

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
| 10 | Without `--open`, the tool pushes or calls GitHub. | Without `--open` it only builds the local branch and writes the body. | yes |
| 11 | With `--open`, issue creation fails. | Exit 1. Push nothing. | yes |
| 12 | Anything asks the tool to merge. | There is no merge path. A person merges after review. | yes |
