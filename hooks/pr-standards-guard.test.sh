#!/usr/bin/env bash
# Check what the guard blocks and, more importantly, what it lets through.
# A guard that misreads a delete as a create traps you on a bad branch name.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${GUARD:-$HERE/pr-standards-guard.sh}"
REPO_ROOT="$(dirname "$HERE")"

# Put the real engine on PATH for the existing local branch-creation cases.
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
ln -s "$REPO_ROOT/pr-standards" "$BIN/pr-standards"
export PATH="$BIN:$PATH"

# The target uses tar, not this checkout's scr prefix. This makes cross-repo
# tests prove the guard reads the target settings through gh, without a network.
gh() {
  case " $* " in
    *' repos/pooriaarab/target-standard/contents/.github/pr-standards.json '*)
      printf '{"prefix":"tar"}' | base64
      ;;
    *' repos/pooriaarab/scripts/contents/.github/pr-standards.json '*)
      printf '{"prefix":"scr"}' | base64
      ;;
    *) return 1 ;;
  esac
}
export -f gh

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
check 0 'ignores a git call hidden in a comment'       'echo ok # note; git checkout -b my-cool-feature'
check 2 'sees a git call on the next line'             $'echo ready\ngit checkout -b my-cool-feature'
check 2 'sees a git call after an env var assignment'  'FOO=bar git checkout -b my-cool-feature'
check 2 'treats -- as end of options for git branch'   'git branch -- my-cool-feature'
check 2 'sees a branch created via git worktree add'   'git worktree add -b my-cool-feature /tmp/tree'
check 0 'allows a conforming cross-repo PR head'       'gh pr create --repo pooriaarab/target-standard --head tar-12-do-one-thing'
check 2 'blocks a bad cross-repo PR head'              'gh pr create --repo pooriaarab/target-standard --head my-cool-feature'
check 0 'ignores a non-pooriaarab PR target'           'gh pr create --repo acme/work --head my-cool-feature'
check 2 'blocks a host-qualified cross-repo PR head'   'gh pr create --repo github.com/pooriaarab/target-standard --head my-cool-feature'
check 0 'strips the owner: fork qualifier from a head' 'gh pr create --repo pooriaarab/target-standard --head alice:tar-12-do-one-thing'
check 2 'routes an explicit same-repo target through the real engine, not the master exemption' \
                                                        'gh pr create --repo pooriaarab/scripts --head master'
check 2 'does not exempt master on a cross-repo target' \
                                                        'gh pr create --repo pooriaarab/target-standard --head master'
check 2 'parses a glued short -R/-H option value'      'gh pr create -Rpooriaarab/target-standard -Hmy-cool-feature'
check 2 'uses the last of a repeated --head, not the first' \
                                                        'gh pr create --repo pooriaarab/target-standard --head tar-12-good --head my-cool-feature'

[ "$fails" = 0 ] || { printf '\n%s failing\n' "$fails" >&2; exit 1; }
printf '\nall passing\n'
