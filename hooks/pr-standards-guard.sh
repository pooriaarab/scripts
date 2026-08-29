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

branch=$(INPUT="$input" python3 <<'PY' 2>/dev/null || true
import json, os, shlex

data = json.loads(os.environ.get("INPUT", ""))
if (data.get("tool_name") or data.get("tool") or "Bash") != "Bash":
    raise SystemExit(0)
command = (data.get("tool_input") or {}).get("command") or data.get("command") or ""

# Split the line into segments on the shell operators, so `cd x && git
# checkout -b y` is still seen while `echo git checkout -b y` is not. A
# segment is only a git invocation when its FIRST word is git; matching the
# word anywhere blocked every command that merely mentioned a branch.
OPERATORS = {"&&", "||", ";", "|", "&"}
segments, current = [], []
for token in shlex.split(command):
    if token in OPERATORS:
        segments.append(current)
        current = []
    else:
        current.append(token)
segments.append(current)

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
        return value_after({"-b", "-B"})
    if rest[0] == "switch":
        return value_after({"-c", "-C"})
    if rest[0] == "branch" and not {"-d", "-D", "--delete", "-m", "-M", "--move"} & set(rest):
        names = [token for token in rest[1:] if not token.startswith("-")]
        return names[0] if names else None
    return None

for tokens in segments:
    if not tokens or os.path.basename(tokens[0]) != "git":
        continue
    name = created_branch(tokens)
    if name:
        print(name)
        break
PY
)

[ -n "$branch" ] || exit 0

if ! output=$(pr-standards precheck --branch "$branch" 2>&1); then
  printf 'Branch "%s" does not meet the PR standard:\n%s\n' "$branch" "$output" >&2
  exit 2
fi
