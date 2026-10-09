# file-dep-restack failure modes

`file-dep-restack` replays a stack of branches onto a new base, commit by
commit. In each commit it rewrites `file:` dependencies on packages that are
now published to a registry range, and it regenerates the lockfile. It keeps
each commit's message and author, so a tests-first history stays visible.

Use it when a stack was built against local `file:` copies of sibling
packages, and those packages are now on npm.

This file lists every way the tool can fail. The tests in
`file-dep-restack.test.sh` cover each row marked "tested".

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | No `--packages`, no old base, or no branch is given. | Print usage, exit 1. | yes |
| 2 | The checkout has uncommitted changes. | Exit 1 before any change. | yes |
| 3 | A named branch does not exist. | Exit 1 before any change. | yes |
| 4 | The branches are not a stack: the old base is not an ancestor of the first branch, or a branch is not an ancestor of the next. | Exit 1 before any change. | yes |
| 5 | A commit conflicts in a file other than `package.json`, the lockfile, or `pnpm-workspace.yaml`. | Exit 1. Move no branch. Return to the starting branch. | yes |
| 6 | A commit conflicts only in `package.json`, the lockfile, or `pnpm-workspace.yaml`. | Take the branch side of `package.json` and the workspace file, then regenerate the lockfile. | yes |
| 7 | The lock command fails (for example, the range is not on the registry yet). | Exit 1 with the log tail. Move no branch. | yes |
| 8 | The rewrite makes a commit empty. | Skip that commit. | no, rare |
| 9 | The replay loses a commit's message or author. | Commit with `git commit -C <original>`, which keeps both. | yes |
| 10 | The replay squashes commits, so tests no longer come before code in history. | Replay one commit at a time. | yes |
| 11 | A `file:` dependency that is not in `--packages` gets rewritten. | Leave it as it is. | yes |
| 12 | A package was published under another name, because npm refused the first name as too similar to an existing one. | `--alias name=npm:other-name@^1.0.0` writes that spec in place of the range. | yes |
| 13 | The lockfile regenerates on every commit, which is slow and needs the network each time. | Regenerate only when `package.json` changed, by the commit or by the rewrite. | yes |
| 14 | pnpm stores `file:` dependencies as paths relative to the checkout, so a worktree in another directory gets a broken lockfile. | Out of scope. The rewrite removes the `file:` specs that cause it. | no, by design |
| 15 | A landing tool that rebases with `--onto <old tip>` reads stale tips after the restack. | `--tips FILE` rewrites the tip of each restacked branch, and sets the entry before the first one to the new base. | yes |
