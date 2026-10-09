# stack-lander failure modes

`stack-lander` prepares one entry of a stacked-branch queue for merge. It
creates the issue, renames the branch to the issue number, rebases it, pushes
it, opens the pull request, and waits for its checks. It never merges.

This file lists every way the tool can fail. The tests in
`stack-lander.test.sh` cover each row marked "tested".

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | The queue file or the entry number does not exist. | Exit 1 before any `gh` or `git` change. | yes |
| 2 | The issue body or PR body file that the entry names is missing. | Exit 1 before the issue exists. | yes |
| 3 | The title is shorter than 10 or longer than 50 characters. | Exit 1 before the issue exists. The checker refuses it later anyway. | yes |
| 4 | The PR body references `./shot.png` and the file is not in the queue directory. | Exit 1 before the issue exists. | yes |
| 5 | The checkout has uncommitted changes. | Exit 1. A rename or rebase would mix them in. | yes |
| 6 | The branch named in the queue does not exist locally. | Exit 1 before the issue exists. | yes |
| 7 | The base branch has no `.github/pr-standards.json` (a new repo). | Use the prefix the checker derives from the repo name, because the checker reads the config from the base branch. | yes |
| 8 | The earlier entries were squash-merged, so the branch shares commits that the base no longer has. | Rebase with `--onto origin/<base> <old tip of entry k-1>`. Record the original tips once, before any rename. | yes |
| 9 | The rebase conflicts. | Abort the rebase, do not push, print how to resume, exit 1. | yes |
| 10 | Issue creation fails (rate limit, bad label). | Exit 1. Do not rename or push. | yes |
| 11 | A check run on the head SHA fails. | Print the table and exit 1. | yes |
| 12 | Checks do not finish, or none register, within the poll budget. | Print the table and exit 2. | yes |
| 13 | Anything asks the tool to merge. | There is no merge path. The test asserts no merge call happens. | yes |
| 14 | `--dry-run` changes state. | Print every `gh` and mutating `git` call. Change nothing. | yes |
| 15 | Several repos land at once and hit the GitHub secondary limit for content creation. | Use REST for issues, PRs, and check polling. Poll at a fixed, slow interval. The only GraphQL call is `gh pr create --attach`, used only when the body has media. | no, by design |
| 16 | A run stops halfway, after the push. | `RESUME_BRANCH` and `ISSUE` skip the issue, rename, rebase, and push steps. | yes |
