#!/usr/bin/env bash
# End-to-end test for disk-hygiene (#607).
#
# Every way the sweep can fail is a case below. Fixtures are real repos with real
# worktrees; the cache tools (npm, bun, pnpm, brew) are stubs that log their calls.
#
#   1  dry run is the default                      -> nothing removed, no cache tool called
#   2  --apply sweeps every repo under every root   -> merged worktrees gone, unmerged kept
#   3  a non-repo directory and an empty root       -> ignored, no crash
#   4  free space above the threshold               -> caches untouched
#   5  free space below the threshold, --apply      -> caches cleared (tools + Xcode dirs)
#   6  free space below the threshold, dry run      -> caches untouched (same run as 1)
#   7  still below the threshold after cleaning     -> status 3 (a warning, not a crash)
#   8  the log records free space before and after  -> asserted
#   9  a run already holds the lock                 -> second run does nothing, exits 0
#  10  the prune script is missing                  -> loud failure, nonzero exit
#  11  the installer's plist                        -> valid, runs --apply, 6-hour interval
#  12  a lock whose owner died (SIGKILL)           -> reclaimed, the run proceeds
#  13  a non-numeric threshold                      -> status 2, nothing removed
#  14  a root that cannot be listed                 -> status 2 naming the root, nothing swept
#  15  the done line counts repos seen              -> repos=N, so a run that read nothing shows repos=0
#  16  the installer's verdict on a log             -> healthy only when repos is above 0
#  17  an unknown installer flag                    -> status 2, and launchctl is never called
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/disk-hygiene"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$tmp"' EXIT

fails=0
check() { if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
gitq() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# --- stubs for the cache tools; each logs argv
mkdir -p "$tmp/bin"
for t in npm bun pnpm brew; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALL_LOG"\n' "$t" > "$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
# gh stub: fails, so a fixture branch never reaches the network
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
# launchctl stub: the installer must never reach the real launchd from a test. An unknown flag once
# ran the whole install and replaced the live agent. Any call is logged, and case 17 asserts none.
printf '#!/usr/bin/env bash\necho "launchctl $*" >> "$LAUNCHCTL_LOG"\nexit 1\n' > "$tmp/bin/launchctl"; chmod +x "$tmp/bin/launchctl"
export LAUNCHCTL_LOG="$tmp/launchctl.log"; : > "$LAUNCHCTL_LOG"
# lsof stub: no live processes, so only the sweep logic is under test here
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/lsof"; chmod +x "$tmp/bin/lsof"
export CALL_LOG="$tmp/calls.log"; : > "$CALL_LOG"
export PATH="$tmp/bin:$PATH"

export HOME="$tmp/home"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData/app" "$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0" \
         "$HOME/Library/Caches/ms-playwright/chromium"
echo x > "$HOME/Library/Developer/Xcode/DerivedData/app/obj"
echo x > "$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0/sym"
echo x > "$HOME/Library/Caches/ms-playwright/chromium/bin"

# --- fixture repo with one merged and one unmerged worktree
make_repo() { # root, name
  local root="$1" name="$2" bare="$tmp/$2.git"
  gitq init -q --bare -b main "$bare"
  gitq clone -q "$bare" "$root/$name" 2>/dev/null
  (cd "$root/$name" && gitq checkout -q -b main && echo base > f && gitq add f && gitq commit -qm base \
    && gitq push -q origin main && gitq remote set-head origin main)
  gitq -C "$root/$name" worktree add -q "$tmp/wt-$name-merged" -b "$name-merged"
  (cd "$tmp/wt-$name-merged" && echo m > m && gitq add m && gitq commit -qm m)
  (cd "$root/$name" && gitq merge -q --ff-only "$name-merged" && gitq push -q origin main)
  gitq -C "$root/$name" worktree add -q "$tmp/wt-$name-open" -b "$name-open"
  (cd "$tmp/wt-$name-open" && echo o > o && gitq add o && gitq commit -qm o)
}
mkdir -p "$tmp/rootA" "$tmp/rootB" "$tmp/rootEmpty" "$tmp/rootA/not-a-repo"
make_repo "$tmp/rootA" alpha
make_repo "$tmp/rootB" beta

export DISK_HYGIENE_ROOTS="$tmp/rootA:$tmp/rootB:$tmp/rootEmpty"
export DISK_HYGIENE_LOG="$tmp/state/log"
export DISK_HYGIENE_LOCK="$tmp/state/lock"
export DISK_HYGIENE_THRESHOLD_GIB=200

run() { "$tool" "$@" > "$tmp/out" 2>&1 && echo 0 > "$tmp/rc" || echo $? > "$tmp/rc"; }
rc() { cat "$tmp/rc"; }
alive() { [[ -d "$tmp/wt-$1" ]]; }
derived="$HOME/Library/Developer/Xcode/DerivedData/app"

# 1 and 6: dry run is the default. Free is low, so a bug that applied would also clear caches.
DISK_HYGIENE_FREE_GIB=10 run
dry_ok=0
for n in alpha beta; do alive "$n-merged" || dry_ok=1; done
[[ -s "$CALL_LOG" ]] && dry_ok=1
[[ -d "$derived" ]] || dry_ok=1
check "1 dry run removes nothing and calls no cache tool" "$dry_ok"
check "6 dry run below the threshold leaves caches alone" "$dry_ok"

# 2, 3, 4: apply above the threshold sweeps but keeps caches
DISK_HYGIENE_FREE_GIB=500 run --apply
c2=0
for n in alpha beta; do alive "$n-merged" && c2=1; alive "$n-open" || c2=1; done
check "2 --apply removes merged worktrees in every root, keeps unmerged" "$c2"
check "3 a non-repo directory and an empty root do not crash it" "$([[ "$(rc)" -eq 0 ]] && echo 0 || echo 1)"
check "4 above the threshold caches are untouched" "$([[ ! -s "$CALL_LOG" && -d "$derived" ]] && echo 0 || echo 1)"

# 5, 7, 8: apply below the threshold
DISK_HYGIENE_FREE_GIB=10 run --apply
cleared=1
if [[ -s "$CALL_LOG" ]] && grep -q '^npm cache clean' "$CALL_LOG" && grep -q '^brew cleanup' "$CALL_LOG" \
   && [[ ! -e "$derived" ]] && [[ ! -e "$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0" ]] \
   && [[ ! -e "$HOME/Library/Caches/ms-playwright/chromium" ]]; then cleared=0; fi
check "5 below the threshold caches are cleared" "$cleared"
check "7 still below the threshold after cleaning reports status 3" "$([[ "$(rc)" -eq 3 ]] && echo 0 || echo 1)"
check "8 the log records free space before and after" "$(grep -q 'free_before_gib=10' "$DISK_HYGIENE_LOG" && grep -q 'free_after_gib=' "$DISK_HYGIENE_LOG" && echo 0 || echo 1)"

# 9: with the lock held, a new merged worktree must survive a run
gitq -C "$tmp/rootA/alpha" worktree add -q "$tmp/wt-late" -b late
(cd "$tmp/wt-late" && echo l > l && gitq add l && gitq commit -qm l)
(cd "$tmp/rootA/alpha" && gitq merge -q --ff-only late && gitq push -q origin main)
mkdir -p "$DISK_HYGIENE_LOCK"; echo "$$" > "$DISK_HYGIENE_LOCK/pid"   # this shell is alive
DISK_HYGIENE_FREE_GIB=500 run --apply
check "9 a lock held by a live pid stops a second run" "$([[ "$(rc)" -eq 0 ]] && alive late && echo 0 || echo 1)"

# 12: the owner was SIGKILLed, so its EXIT trap never ran and the lock stayed behind
sleep 30 & dead=$!; kill -9 "$dead"; wait "$dead" 2>/dev/null || true
echo "$dead" > "$DISK_HYGIENE_LOCK/pid"
DISK_HYGIENE_FREE_GIB=500 run --apply
check "12 a lock whose owner died is reclaimed and the run proceeds" "$([[ "$(rc)" -eq 0 ]] && ! alive late && grep -q 'reclaiming stale lock' "$tmp/out" && [[ ! -e "$DISK_HYGIENE_LOCK" ]] && echo 0 || echo 1)"

# 13: a bad threshold must stop the run before it touches anything
gitq -C "$tmp/rootA/alpha" worktree add -q "$tmp/wt-later" -b later
(cd "$tmp/wt-later" && echo z > z && gitq add z && gitq commit -qm z)
(cd "$tmp/rootA/alpha" && gitq merge -q --ff-only later && gitq push -q origin main)
DISK_HYGIENE_THRESHOLD_GIB=lots DISK_HYGIENE_FREE_GIB=500 run --apply
check "13 a non-numeric threshold reports status 2 and removes nothing" "$([[ "$(rc)" -eq 2 ]] && alive later && echo 0 || echo 1)"

# 10: missing prune script
DISK_HYGIENE_PRUNE="$tmp/nope.sh" DISK_HYGIENE_FREE_GIB=500 run --apply
check "10 a missing prune script fails loudly" "$([[ "$(rc)" -ne 0 ]] && grep -qi 'prune' "$tmp/out" && echo 0 || echo 1)"

# 11: the launchd plist must parse and must pass --apply (a dry-run agent would do nothing, forever)
"$here/disk-hygiene-install" --print > "$tmp/agent.plist"
plist_ok=1
python3 - "$tmp/agent.plist" <<'PY' && plist_ok=0
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
cmd = d["ProgramArguments"][-1]
assert d["Label"] == "com.pooriaarab.disk-hygiene"
assert "disk-hygiene" in cmd and cmd.rstrip().endswith("--apply"), cmd
assert d["StartInterval"] == 21600 and d["RunAtLoad"] is True
PY
check "11 the installer plist is valid and runs --apply every 6 hours" "$plist_ok"

# 14: a root that cannot be listed. macOS gives launchd exactly this for ~/Documents without
# Full Disk Access: the directory test passes, the listing fails, and a glob matches nothing.
# Skipped as root, where chmod 000 blocks nothing.
if [[ "$(id -u)" -ne 0 ]]; then
  mkdir -p "$tmp/rootLocked/hidden-repo"; chmod 000 "$tmp/rootLocked"
  DISK_HYGIENE_ROOTS="$tmp/rootLocked:$tmp/rootA" DISK_HYGIENE_FREE_GIB=500 run --apply
  locked_rc="$(rc)"; chmod 755 "$tmp/rootLocked"
  check "14 an unreadable root reports status 2, names the root and sweeps nothing" "$([[ "$locked_rc" -eq 2 ]] && grep -q 'rootLocked' "$tmp/out" && ! grep -q 'repo=' "$tmp/out" && echo 0 || echo 1)"
else
  echo "skip 14 (running as root)"
fi

# 15: a normal run reports how many repos it saw
DISK_HYGIENE_FREE_GIB=500 run --apply
check "15 the done line reports repos seen" "$(grep -q ' done repos=2 ' "$tmp/out" && echo 0 || echo 1)"

# 16: the installer reads the same log and must not call a run that read nothing healthy
printf '2026-10-26T16:01:38Z done repos=0 swept=0 removed=0 needs_review=0 caches_cleared=no free_before_gib=36 free_after_gib=36\n' > "$tmp/blind.log"
printf '2026-10-26T16:29:47Z done repos=33 swept=33 removed=35 needs_review=110 caches_cleared=no free_before_gib=32 free_after_gib=37\n' > "$tmp/sighted.log"
printf '2026-10-26T16:29:47Z start mode=apply\n' > "$tmp/nodone.log"
"$here/disk-hygiene-install" --verdict "$tmp/blind.log" > "$tmp/v1.out" 2>&1 && v1=0 || v1=$?
"$here/disk-hygiene-install" --verdict "$tmp/sighted.log" > "$tmp/v2.out" 2>&1 && v2=0 || v2=$?
"$here/disk-hygiene-install" --verdict "$tmp/nodone.log" > "$tmp/v3.out" 2>&1 && v3=0 || v3=$?
check "16 a run that saw no repos is not healthy and names Full Disk Access" "$([[ "$v1" -ne 0 ]] && grep -q 'Full Disk Access' "$tmp/v1.out" && echo 0 || echo 1)"
check "16 a run that saw repos is healthy" "$([[ "$v2" -eq 0 ]] && echo 0 || echo 1)"
check "16 a log with no done line is not healthy" "$([[ "$v3" -ne 0 ]] && echo 0 || echo 1)"

# 17: an unknown flag must be refused before any side effect
"$here/disk-hygiene-install" --no-such-flag > "$tmp/v4.out" 2>&1 && v4=0 || v4=$?
check "17 an unknown installer flag reports status 2 and never calls launchctl" "$([[ "$v4" -eq 2 && ! -s "$LAUNCHCTL_LOG" ]] && echo 0 || echo 1)"

if [[ "$fails" -ne 0 ]]; then echo "--- last out"; cat "$tmp/out"; echo "$fails case(s) failed" >&2; exit 1; fi
echo "all cases passed"
