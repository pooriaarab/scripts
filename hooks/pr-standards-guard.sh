#!/usr/bin/env bash
# A Claude Code PreToolUse hook: reject a branch that does not meet the PR
# standard before the branch exists. This is layer one of four, and the
# earliest feedback available — the git pre-push hook (install-pr-hooks) and
# the CI check both run later. See pr-standards.md.
#
# Install: in .claude/settings.json, under hooks.PreToolUse, matcher "Bash",
#   { "type": "command", "command": "<path>/hooks/pr-standards-guard.sh" }
#
# A hook that cannot understand its own input lets the call through. Blocking
# on its own bug would be worse than the branch name it is guarding against.
set -uo pipefail

command -v pr-standards >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input=$(cat || true)
[ -n "$input" ] || exit 0

branches=$(INPUT="$input" python3 <<'PY' 2>/dev/null || true
import json, os, re, shlex

data = json.loads(os.environ.get("INPUT", ""))
if (data.get("tool_name") or data.get("tool") or "Bash") != "Bash":
    raise SystemExit(0)
command = (data.get("tool_input") or {}).get("command") or data.get("command") or ""

# Split the line into segments on the shell operators, so `cd x && git
# checkout -b y` is still seen while `echo git checkout -b y` is not. A
# segment is only a git invocation when its FIRST word is git; matching the
# word anywhere blocked every command that merely mentioned a branch.
#
# Pad the operators before tokenising. shlex keeps `true&&git` as one token, so
# an unspaced operator hid the git call from the whole guard.
OPERATORS = {"&&", "||", ";", "|", "&"}
padded = re.sub(r"(\|\||&&|;|\||&)", r" \1 ", command)
segments, current = [], []
for token in shlex.split(padded):
    if token in OPERATORS:
        segments.append(current)
        current = []
    else:
        current.append(token)
segments.append(current)

# `git branch` is mostly a query. Only these flags can accompany a creation, so
# any other flag means the line lists or inspects branches and creates nothing.
# Validating a `--list` pattern made the guard block a harmless command, which
# is the one failure this hook must never have.
BRANCH_CREATE_FLAGS = {"-f", "--force", "-t", "--track", "--no-track", "-c", "-C", "--copy"}
BRANCH_COPY_FLAGS = {"-c", "-C", "--copy"}


def created_branch(tokens):
    # Skip git's own global flags, so `git -C dir checkout -b x` still parses.
    index = 1
    while index < len(tokens) and tokens[index].startswith("-"):
        index += 2 if tokens[index] in {"-C", "-c", "--git-dir", "--work-tree"} else 1
    rest = tokens[index:]
    if not rest:
        return None

    def value_after(flags):
        for position, token in enumerate(rest[:-1]):
            if token in flags and not rest[position + 1].startswith("-"):
                return rest[position + 1]
        return None

    # Only branch CREATION is checked. Deleting or renaming a branch is how you
    # recover from a bad name, so a guard that blocked those would trap you.
    if rest[0] == "checkout":
        return value_after({"-b", "-B", "--orphan"})
    if rest[0] == "switch":
        return value_after({"-c", "-C", "--orphan"})
    if rest[0] == "branch":
        flags = {token for token in rest[1:] if token.startswith("-")}
        if not flags <= BRANCH_CREATE_FLAGS:
            return None
        names = [token for token in rest[1:] if not token.startswith("-")]
        if not names:
            return None
        # `git branch -c <source> <new>` copies. The new name is the last one,
        # and it is the only one this guard has any say over.
        return names[-1] if flags & BRANCH_COPY_FLAGS else names[0]
    return None


# Every segment is checked. A chain that creates two branches used to have only
# its first name validated, so the bad second name went through unseen.
for tokens in segments:
    if not tokens or os.path.basename(tokens[0]) != "git":
        continue
    name = created_branch(tokens)
    if name:
        print(name)
PY
)

[ -n "$branches" ] || exit 0

status=0
while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  if ! output=$(pr-standards precheck --branch "$branch" 2>&1); then
    printf 'Branch "%s" does not meet the PR standard:\n%s\n' "$branch" "$output" >&2
    status=2
  fi
done <<< "$branches"
exit "$status"
