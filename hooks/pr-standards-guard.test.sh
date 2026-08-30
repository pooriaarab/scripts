#!/usr/bin/env bash
# Check what the guard blocks and, more importantly, what it lets through.
# A guard that misreads a delete as a create traps you on a bad branch name.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/pr-standards-guard.sh"
REPO_ROOT="$(dirname "$HERE")"

# The guard exits 0 when `pr-standards` is not on PATH, so put the real one there.
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
ln -s "$REPO_ROOT/pr-standards" "$BIN/pr-standards"
export PATH="$BIN:$PATH"

fails=0
check() {
  local want="$1" name="$2" command="$3" got
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$command")" \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s (want exit %s, got %s)\n' "$name" "$want" "$got"
    fails=$((fails + 1))
  fi
}

check 2 'blocks a branch created with no issue number' 'git checkout -b my-cool-feature'
check 2 'blocks the -c form of git switch'             'git switch -c my-cool-feature'
check 0 'allows a conforming branch'                   'git checkout -b scr-12-do-one-thing'
check 0 'allows a checkout that creates nothing'       'git checkout main'
check 0 'allows deleting a badly named branch'         'git branch -D my-cool-feature'
check 0 'allows renaming a badly named branch'         'git branch -m my-cool-feature scr-12-do-one-thing'
check 0 'ignores a command that is not git'            'echo git checkout -b nope'
check 0 'lets unparseable input through'               'git checkout -b "unterminated'
check 2 'blocks an orphan branch'                      'git checkout --orphan my-cool-feature'
check 2 'blocks the orphan form of git switch'         'git switch --orphan my-cool-feature'
check 2 'checks the copy target, not the source'       'git branch -c scr-12-do-one-thing my-cool-feature'
check 2 'sees a git call after an unspaced operator'   'true&&git checkout -b my-cool-feature'
check 2 'checks every branch a chain creates'          'git checkout -b scr-12-do-one-thing && git checkout -b my-cool-feature'
check 0 'allows listing branches by pattern'           'git branch --list my-cool-*'
check 0 'allows showing the current branch'            'git branch --show-current'

[ "$fails" = 0 ] || { printf '\n%s failing\n' "$fails" >&2; exit 1; }
printf '\nall passing\n'
