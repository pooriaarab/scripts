#!/usr/bin/env bash
# End-to-end test for prune-merged-worktrees.sh (#606).
#
# Every way the script can fail is a case below. Each case is a real worktree in a
# real fixture repo; `gh` is a stub that serves canned PR data and logs its argv.
#
#   A  merged and clean                              -> removed
#   B  squash-merged (PR head == tip, not ancestor)  -> removed
#   C  PR merged, then more commits on the branch    -> kept (head SHA != tip)
#   D  PR closed without merge                       -> kept (closed is no evidence)
#   E  merged, but holds an ignored .env.local       -> kept, needs-review
#   F  merged, ignored node_modules + .next only     -> removed (regenerable).
#      F follows E, so it also proves a worktree after a needs-review one is not skipped.
#   G  merged, a live process runs inside it         -> kept (skipped)
#   H  repo whose default branch is `trunk`          -> merged worktree removed
#   I  gh is called with --repo <slug from origin>   -> asserted from the stub log
#   J  dry run removes nothing                       -> asserted before --apply
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/prune-merged-worktrees.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
live_pid=""
cleanup() { if [[ -n "$live_pid" ]]; then kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true; fi; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "$tmp"; }
trap cleanup EXIT

fails=0
check() { # name, condition-exit-code
  if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# --- gh stub: `gh pr list --repo S --head B --state merged --json headRefOid --jq ...`
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
head=""; state=""; repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --head) head="$2"; shift ;;
    --state) state="$2"; shift ;;
    --repo) repo="$2"; shift ;;
  esac
  shift
done
[[ "$repo" == "test/fixture" ]] || exit 1   # a wrong or missing --repo must fail the lookup
[[ "$state" == "merged" ]] || exit 0         # closed or open PRs are never listed as merged
f="$GH_DATA/$head"
[[ -f "$f" ]] && cat "$f"
exit 0
STUB
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log" GH_DATA="$tmp/ghdata"
mkdir -p "$GH_DATA"; : > "$GH_LOG"
export PATH="$tmp/bin:$PATH"

# --- fixture: origin (bare) and main clone with default branch $1
make_repo() { # name, default-branch
  local name="$1" def="$2"
  gitq init -q --bare -b "$def" "$tmp/$name.git"
  gitq clone -q "$tmp/$name.git" "$tmp/$name" 2>/dev/null
  (cd "$tmp/$name" && gitq checkout -q -b "$def" && echo base > f && printf 'node_modules\n.next\n.env.local\n' > .gitignore \
    && gitq add . && gitq commit -qm base && gitq push -q origin "$def" && gitq remote set-head origin "$def")
  # origin looks like GitHub, but fetches from the local bare repo
  gitq -C "$tmp/$name" config "url.$tmp/$name.git.insteadOf" "https://github.com/test/fixture.git"
  gitq -C "$tmp/$name" remote set-url origin "https://github.com/test/fixture.git"
}
add_wt() { # repo, name -> creates branch+worktree at tmp/wt-name
  gitq -C "$tmp/$1" worktree add -q "$tmp/wt-$2" -b "$2" "$3"
}

make_repo main main
def_ref=origin/main
r="$tmp/main"

# A: merged and clean — branch tip is on main
add_wt main a "$def_ref"
(cd "$tmp/wt-a" && echo a > a && gitq add a && gitq commit -qm a)
(cd "$r" && gitq merge -q --ff-only a && gitq push -q origin main)

# B: squash-merged — tip is NOT an ancestor of main; PR head SHA == tip
add_wt main b "$def_ref"
(cd "$tmp/wt-b" && echo b > b && gitq add b && gitq commit -qm b)
b_tip="$(gitq -C "$tmp/wt-b" rev-parse HEAD)"
(cd "$r" && echo squash >> f && gitq commit -qam "squash b" && gitq push -q origin main)
echo "$b_tip" > "$GH_DATA/b"

# C: PR merged at an older SHA, then a new commit landed on the branch
add_wt main c "$def_ref"
(cd "$tmp/wt-c" && echo c1 > c && gitq add c && gitq commit -qm c1)
c_old="$(gitq -C "$tmp/wt-c" rev-parse HEAD)"
(cd "$tmp/wt-c" && echo c2 > c2 && gitq add c2 && gitq commit -qm c2)
echo "$c_old" > "$GH_DATA/c"

# D: closed PR, never merged (the stub lists nothing for it)
add_wt main d "$def_ref"
(cd "$tmp/wt-d" && echo d > d && gitq add d && gitq commit -qm d)

# E: merged and clean in git, but holds an ignored .env.local
add_wt main e "$def_ref"
(cd "$tmp/wt-e" && echo e > e && gitq add e && gitq commit -qm e)
(cd "$r" && gitq merge -q --no-edit e && gitq push -q origin main)
echo "SECRET=1" > "$tmp/wt-e/.env.local"

# F: merged; ignored files are only node_modules and .next (regenerable)
add_wt main f "$def_ref"
(cd "$tmp/wt-f" && echo f > f2 && gitq add f2 && gitq commit -qm f)
(cd "$r" && gitq merge -q --no-edit f && gitq push -q origin main)
mkdir -p "$tmp/wt-f/node_modules/x" "$tmp/wt-f/.next"; echo x > "$tmp/wt-f/node_modules/x/i.js"

# G: merged and clean, but a process has its cwd inside
add_wt main g "$def_ref"
(cd "$tmp/wt-g" && echo g > g && gitq add g && gitq commit -qm g)
(cd "$r" && gitq merge -q --no-edit g && gitq push -q origin main)
(cd "$tmp/wt-g" && exec sleep 300) & live_pid=$!
sleep 0.3

# H: default branch is trunk, not main
make_repo trunkrepo trunk
add_wt trunkrepo h origin/trunk
(cd "$tmp/wt-h" && echo h > h && gitq add h && gitq commit -qm h)
(cd "$tmp/trunkrepo" && gitq merge -q --ff-only h && gitq push -q origin trunk)

# J: dry run first
"$script" "$r" > "$tmp/dry.out" 2>&1 || true
dry_gone=0; for w in a b e f g; do [[ -d "$tmp/wt-$w" ]] || dry_gone=1; done
check "J dry run removes nothing" "$dry_gone"

"$script" "$r" --apply > "$tmp/main.out" 2>&1 || true
"$script" "$tmp/trunkrepo" --apply > "$tmp/trunk.out" 2>&1 || true

gone() { [[ ! -d "$tmp/wt-$1" ]]; }
kept() { [[ -d "$tmp/wt-$1" ]]; }
check "A merged and clean is removed"            "$(gone a && echo 0 || echo 1)"
check "B squash-merged (PR head == tip) removed" "$(gone b && echo 0 || echo 1)"
check "C commits after the merge are kept"       "$(kept c && echo 0 || echo 1)"
check "D closed-only PR is kept"                 "$(kept d && echo 0 || echo 1)"
check "E ignored .env.local is kept"             "$(kept e && echo 0 || echo 1)"
check "E ... and reported as needs-review"       "$(grep -q 'needs-review: 1' "$tmp/main.out" && grep -q 'wt-e' "$tmp/main.out" && echo 0 || echo 1)"
check "F regenerable ignored files are removed"  "$(gone f && echo 0 || echo 1)"
check "G worktree with a live process is kept"   "$(kept g && echo 0 || echo 1)"
check "H default branch trunk is honoured"       "$(gone h && echo 0 || echo 1)"
check "I gh is always passed --repo test/fixture" "$( [[ -s "$GH_LOG" ]] && ! grep -v -e '--repo test/fixture' "$GH_LOG" | grep -q . && echo 0 || echo 1)"

if [[ "$fails" -ne 0 ]]; then
  echo "--- main.out"; cat "$tmp/main.out"; echo "--- gh.log"; cat "$GH_LOG"
  echo "$fails case(s) failed" >&2; exit 1
fi
echo "all cases passed"
