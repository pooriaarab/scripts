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
#  18  an old success, then a run that never ended  -> not healthy (judge the LAST run)
#  19  a clone git cannot read                      -> not counted, failed=1, status 2, others still swept
#  20  extra arguments after --verdict LOGFILE      -> status 2
#  21  a failure before the sweep starts           -> recorded, so an old success cannot stand
#  22  install verification                        -> only a finish line written AFTER the install counts
#  23  a prune failure                             -> counted in failed=N, swept not counted, status 2
#  24  error text that contains " done "            -> still an error record, never a finish line
#  25  a lock directory that cannot be made        -> recorded, status 2
#  26  a repo directory that cannot be read        -> counted in failed=N, status 2
#  27  a failed verification                       -> leaves no temp file behind (a guard: the previous
#                                                     code did not leak on bash 5 either)
#  22b an old process finishing during the install -> its finish line has no run id and is ignored
#  28  a lock skip                                  -> recorded, so an old success cannot stand; an old empty lock is reclaimed
#  29  setup checks run under the lock              -> a second run records a skip, not an error between start and done
#  30  free space unreadable after the sweep        -> recorded, status 2
#  31  a success that is days old                   -> not healthy: a dead agent or unwritable log shows as stale
#  32  an unexpected exit (a lock that cannot go)   -> an error record, so the old success cannot stand
#  33  a newline in an env value                    -> cannot forge a finish line
#  34  an unwritable log                            -> the sweep exits non-zero and says so
#  35  the installer's launchd logs                 -> truncated before the job starts, never deleted
#  36  a run id that carries fields                 -> refused; and the verdict reads the FIRST repos= and failed= tokens
#  37  df prints a table, then fails                -> an error, not a reading
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
cat > "$tmp/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LAUNCHCTL_LOG"
[[ "${LAUNCHCTL_MODE:-fail}" == "ok" ]] || exit 1
state="$HOME/.local/state/disk-hygiene"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# the run id the installer put in the plist, so a stubbed "new run" can carry it
id="$(awk '/DISK_HYGIENE_RUN_ID/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print }' "$HOME/Library/LaunchAgents/com.pooriaarab.disk-hygiene.plist" 2>/dev/null)"
if [[ "$1" == "bootout" && -n "${LAUNCHCTL_APPEND_OLD:-}" ]]; then
  # the OLD process finishes while the installer replaces it: a finish line with no run id
  printf '%s done repos=3 swept=1 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90\n' "$(ts)" >> "$state/log"
fi
if [[ "$1" == "bootstrap" && -n "${LAUNCHCTL_APPEND_DONE:-}" ]]; then
  repos=3; [[ "$LAUNCHCTL_APPEND_DONE" == "blind" ]] && repos=0
  printf '%s start mode=apply run=%s\n%s done repos=%s swept=1 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90 run=%s\n' \
    "$(ts)" "$id" "$(ts)" "$repos" "$id" >> "$state/log"
fi
exit 0
STUB
chmod +x "$tmp/bin/launchctl"
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
printf '%s done repos=0 swept=0 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=36 free_after_gib=36\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/blind.log"
printf '%s done repos=33 swept=33 removed=35 needs_review=110 failed=0 caches_cleared=no free_before_gib=32 free_after_gib=37\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/sighted.log"
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

# 18: the verdict judges the last run. An old success must not hide a newer run that never finished.
printf '2026-10-26T10:00:00Z start mode=apply\n2026-10-26T10:00:09Z done repos=2 swept=2 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90\n2026-10-26T10:05:00Z start mode=apply\n' > "$tmp/masked.log"
"$here/disk-hygiene-install" --verdict "$tmp/masked.log" > "$tmp/v5.out" 2>&1 && v5=0 || v5=$?
check "18 an old success does not hide a later run that never finished" "$([[ "$v5" -ne 0 ]] && echo 0 || echo 1)"

# 19: a clone whose .git is unreadable must not count as seen. Git fails on it; the sweep says so and
# still sweeps the other roots.
mkdir -p "$tmp/rootBroken/broken/.git"
DISK_HYGIENE_ROOTS="$tmp/rootBroken:$tmp/rootA" DISK_HYGIENE_FREE_GIB=500 run --apply
broken_rc="$(rc)"
check "19 an unreadable clone is not counted, is reported, and status is 2" "$([[ "$broken_rc" -eq 2 ]] && grep -q ' done repos=1 ' "$tmp/out" && grep -q 'failed=1' "$tmp/out" && grep -q 'broken' "$tmp/out" && echo 0 || echo 1)"
grep ' done ' "$tmp/out" > "$tmp/broken.log" || true
"$here/disk-hygiene-install" --verdict "$tmp/broken.log" > "$tmp/v6.out" 2>&1 && v6=0 || v6=$?
check "19 a sweep with a failed clone is not healthy" "$([[ "$v6" -ne 0 ]] && echo 0 || echo 1)"

# 20: extra arguments after the log file
"$here/disk-hygiene-install" --verdict "$tmp/sighted.log" --bad > "$tmp/v7.out" 2>&1 && v7=0 || v7=$?
check "20 extra arguments after --verdict LOGFILE report status 2" "$([[ "$v7" -eq 2 ]] && echo 0 || echo 1)"

# 21: every attempt is recorded, so a failure before the sweep starts cannot leave an old success as
# "the last sweep". One shared log: a good run, then a missing prune script, then a bad threshold.
log21="$tmp/state/log21"
DISK_HYGIENE_LOG="$log21" DISK_HYGIENE_FREE_GIB=500 run --apply
"$here/disk-hygiene-install" --verdict "$log21" > /dev/null 2>&1 && good21=0 || good21=1
DISK_HYGIENE_LOG="$log21" DISK_HYGIENE_PRUNE="$tmp/nope.sh" DISK_HYGIENE_FREE_GIB=500 run --apply
"$here/disk-hygiene-install" --verdict "$log21" > /dev/null 2>&1 && after_missing=0 || after_missing=1
DISK_HYGIENE_LOG="$log21" DISK_HYGIENE_FREE_GIB=500 run --apply
DISK_HYGIENE_LOG="$log21" DISK_HYGIENE_THRESHOLD_GIB=lots DISK_HYGIENE_FREE_GIB=500 run --apply
"$here/disk-hygiene-install" --verdict "$log21" > /dev/null 2>&1 && after_threshold=0 || after_threshold=1
check "21 a good run is healthy, but not after a missing prune script or a bad threshold" "$([[ "$good21" -eq 0 && "$after_missing" -eq 1 && "$after_threshold" -eq 1 ]] && echo 0 || echo 1)"

# 22: the installer must not accept a finish line that existed before it ran. Second-resolution
# timestamps cannot tell old from new, so it counts log lines written after the install began.
mkdir -p "$tmp/unamebin"; printf '#!/usr/bin/env bash\necho Darwin\n' > "$tmp/unamebin/uname"; chmod +x "$tmp/unamebin/uname"
mkdir -p "$HOME/.local/state/disk-hygiene"
printf '%s start mode=apply\n%s done repos=3 swept=1 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME/.local/state/disk-hygiene/log"
: > "$LAUNCHCTL_LOG"
PATH="$tmp/unamebin:$PATH" LAUNCHCTL_MODE=ok DISK_HYGIENE_INSTALL_LOOPS=3 DISK_HYGIENE_INSTALL_POLL=0.1 \
  "$here/disk-hygiene-install" > "$tmp/i1.out" 2>&1 && i1=0 || i1=$?
check "22 an old finish line does not make a new install healthy" "$([[ "$i1" -ne 0 ]] && ! grep -q 'agent healthy' "$tmp/i1.out" && echo 0 || echo 1)"
PATH="$tmp/unamebin:$PATH" LAUNCHCTL_MODE=ok LAUNCHCTL_APPEND_DONE=good DISK_HYGIENE_INSTALL_LOOPS=20 DISK_HYGIENE_INSTALL_POLL=0.1 \
  "$here/disk-hygiene-install" > "$tmp/i2.out" 2>&1 && i2=0 || i2=$?
check "22 a finish line written after the install makes it healthy, with no kickstart" "$([[ "$i2" -eq 0 ]] && grep -q 'agent healthy' "$tmp/i2.out" && ! grep -q 'kickstart' "$LAUNCHCTL_LOG" && echo 0 || echo 1)"

# 23: a prune that fails is a failed repo. It must not count as swept, and the run must say so.
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/prune-fails.sh"; chmod +x "$tmp/prune-fails.sh"
DISK_HYGIENE_ROOTS="$tmp/rootA" DISK_HYGIENE_PRUNE="$tmp/prune-fails.sh" DISK_HYGIENE_FREE_GIB=500 run --apply
fail_rc="$(rc)"; grep ' done ' "$tmp/out" > "$tmp/prunefail.log" || true
"$here/disk-hygiene-install" --verdict "$tmp/prunefail.log" > /dev/null 2>&1 && pv=0 || pv=1
check "23 a prune failure is counted, not swept, and the run is not healthy" "$([[ "$fail_rc" -eq 2 ]] && grep -q 'swept=0' "$tmp/out" && grep -q 'failed=1' "$tmp/out" && [[ "$pv" -eq 1 ]] && echo 0 || echo 1)"

# 22b: the old process finishes between the stop and the start. Its finish line carries no run id.
printf '%s start mode=apply\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME/.local/state/disk-hygiene/log"
PATH="$tmp/unamebin:$PATH" LAUNCHCTL_MODE=ok LAUNCHCTL_APPEND_OLD=1 DISK_HYGIENE_INSTALL_LOOPS=3 DISK_HYGIENE_INSTALL_POLL=0.1 \
  "$here/disk-hygiene-install" > "$tmp/i3.out" 2>&1 && i3=0 || i3=$?
check "22b a finish line from the old process does not make the install healthy" "$([[ "$i3" -ne 0 ]] && ! grep -q 'agent healthy' "$tmp/i3.out" && echo 0 || echo 1)"

# 27: a verification that fails must clean up its temp file. The new run read 0 repos, so it fails.
mkdir -p "$tmp/tmpx"
TMPDIR="$tmp/tmpx" PATH="$tmp/unamebin:$PATH" LAUNCHCTL_MODE=ok LAUNCHCTL_APPEND_DONE=blind DISK_HYGIENE_INSTALL_LOOPS=20 DISK_HYGIENE_INSTALL_POLL=0.1 \
  "$here/disk-hygiene-install" > "$tmp/i4.out" 2>&1 && i4=0 || i4=$?
check "27 a failed verification names Full Disk Access and leaves no temp file" "$([[ "$i4" -ne 0 ]] && grep -q 'Full Disk Access' "$tmp/i4.out" && [[ -z "$(ls -A "$tmp/tmpx")" ]] && echo 0 || echo 1)"

# 24: error text that contains " done repos=1 failed=0 " must not read as a finish line
log24="$tmp/state/log24"
DISK_HYGIENE_LOG="$log24" DISK_HYGIENE_FREE_GIB=500 run --apply
DISK_HYGIENE_LOG="$log24" DISK_HYGIENE_PRUNE="/tmp/ done repos=1 failed=0 x" DISK_HYGIENE_FREE_GIB=500 run --apply
"$here/disk-hygiene-install" --verdict "$log24" > /dev/null 2>&1 && v24=0 || v24=1
check "24 error text that contains ' done ' is not a finish line" "$([[ "$v24" -eq 1 ]] && echo 0 || echo 1)"

# 25: the lock directory cannot be made. The log must still say so.
log25="$tmp/state/log25"
DISK_HYGIENE_LOG="$log25" DISK_HYGIENE_FREE_GIB=500 run --apply
: > "$tmp/blocker"
DISK_HYGIENE_LOG="$log25" DISK_HYGIENE_LOCK="$tmp/blocker/lock" DISK_HYGIENE_FREE_GIB=500 run --apply
lock_rc="$(rc)"
"$here/disk-hygiene-install" --verdict "$log25" > /dev/null 2>&1 && v25=0 || v25=1
check "25 a lock directory that cannot be made reports status 2 and is not healthy" "$([[ "$lock_rc" -eq 2 && "$v25" -eq 1 ]] && echo 0 || echo 1)"

# 26: a repo directory the sweep cannot read is a failed repo. It is not "a directory that is not a repo".
if [[ "$(id -u)" -ne 0 ]]; then
  mkdir -p "$tmp/rootDenied/denied" "$tmp/rootDenied/fine"
  gitq init -q "$tmp/rootDenied/fine" 2>/dev/null; chmod 000 "$tmp/rootDenied/denied"
  DISK_HYGIENE_ROOTS="$tmp/rootDenied" DISK_HYGIENE_FREE_GIB=500 run --apply
  denied_rc="$(rc)"; chmod 755 "$tmp/rootDenied/denied"
  check "26 an unreadable repo directory is counted as failed and the run reports status 2" "$([[ "$denied_rc" -eq 2 ]] && grep -q 'failed=1' "$tmp/out" && grep -q 'denied' "$tmp/out" && echo 0 || echo 1)"
else
  echo "skip 26 (running as root)"
fi

# 28: a skipped run leaves a record. An empty lock directory (its owner died between mkdir and writing
# the pid) used to make every later run skip in silence while the last success stayed "healthy".
log28="$tmp/state/log28"
DISK_HYGIENE_LOG="$log28" DISK_HYGIENE_FREE_GIB=500 run --apply
mkdir -p "$DISK_HYGIENE_LOCK"                                  # fresh and empty: held, so skip
DISK_HYGIENE_LOG="$log28" DISK_HYGIENE_FREE_GIB=500 run --apply
skip_rc="$(rc)"
"$here/disk-hygiene-install" --verdict "$log28" > /dev/null 2>&1 && v28=0 || v28=1
touch -t 202001010000 "$DISK_HYGIENE_LOCK"                     # the same empty lock, hours old: reclaim
DISK_HYGIENE_LOG="$log28" DISK_HYGIENE_FREE_GIB=500 run --apply
reclaim_rc="$(rc)"
"$here/disk-hygiene-install" --verdict "$log28" > /dev/null 2>&1 && v28b=0 || v28b=1
check "28 a skipped run is recorded and not healthy; an old empty lock is reclaimed" "$([[ "$skip_rc" -eq 0 && "$v28" -eq 1 && "$reclaim_rc" -eq 0 && "$v28b" -eq 0 ]] && echo 0 || echo 1)"

# 29: with a live owner holding the lock, a second run with a bad setup must skip, not write an error
# in the middle of the owner's run.
log29="$tmp/state/log29"
mkdir -p "$DISK_HYGIENE_LOCK"; echo "$$" > "$DISK_HYGIENE_LOCK/pid"
DISK_HYGIENE_LOG="$log29" DISK_HYGIENE_PRUNE="$tmp/nope.sh" DISK_HYGIENE_FREE_GIB=500 run --apply
second_rc="$(rc)"; last29="$(tail -n 1 "$log29" | awk '{ print $2 }')"
rm -rf "$DISK_HYGIENE_LOCK"
check "29 a second run under a held lock records a skip, not a setup error" "$([[ "$second_rc" -eq 0 && "$last29" == "skipped" ]] && echo 0 || echo 1)"

# 30: free space unreadable after the sweep started. df answers once, then fails.
mkdir -p "$tmp/dfbin"
cat > "$tmp/dfbin/df" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$DF_COUNT" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$DF_COUNT"
[[ "$n" -eq 0 ]] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 976490576 1000 943718400 1%% /\n'
STUB
chmod +x "$tmp/dfbin/df"; : > "$tmp/df.count"; rm -f "$tmp/df.count"
log30="$tmp/state/log30"
PATH="$tmp/dfbin:$PATH" DF_COUNT="$tmp/df.count" DISK_HYGIENE_ROOTS="$tmp/rootB" DISK_HYGIENE_LOG="$log30" DISK_HYGIENE_FREE_GIB='' run --apply
df_rc="$(rc)"
"$here/disk-hygiene-install" --verdict "$log30" > /dev/null 2>&1 && v30=0 || v30=1
check "30 free space unreadable after the sweep is recorded and reports status 2" "$([[ "$df_rc" -eq 2 && "$v30" -eq 1 ]] && grep -q ' error ' "$log30" && echo 0 || echo 1)"

# 31: "healthy" must mean recent. A success three days old says nothing about an agent that stopped.
old_ts="$(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '%s done repos=3 swept=1 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90\n' "$old_ts" > "$tmp/old.log"
"$here/disk-hygiene-install" --verdict "$tmp/old.log" > "$tmp/v8.out" 2>&1 && v8=0 || v8=$?
check "31 a success that is days old is not healthy and names its age" "$([[ "$v8" -ne 0 ]] && grep -qi 'old' "$tmp/v8.out" && echo 0 || echo 1)"

# 32: an unexpected exit must leave an error record. A lock directory that cannot be emptied makes rm
# fail under set -e, before any repo is read; the old success used to stay authoritative.
if [[ "$(id -u)" -ne 0 ]]; then
  log32="$tmp/state/log32"
  DISK_HYGIENE_LOG="$log32" DISK_HYGIENE_FREE_GIB=500 run --apply
  sleep 30 & gone=$!; kill -9 "$gone"; wait "$gone" 2>/dev/null || true
  mkdir -p "$DISK_HYGIENE_LOCK"; echo "$gone" > "$DISK_HYGIENE_LOCK/pid"; chmod 500 "$DISK_HYGIENE_LOCK"
  DISK_HYGIENE_LOG="$log32" DISK_HYGIENE_FREE_GIB=500 run --apply
  unexpected_rc="$(rc)"; chmod 755 "$DISK_HYGIENE_LOCK"; rm -rf "$DISK_HYGIENE_LOCK"
  "$here/disk-hygiene-install" --verdict "$log32" > /dev/null 2>&1 && v32=0 || v32=1
  check "32 an unexpected exit leaves an error record and the old success cannot stand" "$([[ "$unexpected_rc" -ne 0 && "$v32" -eq 1 ]] && tail -n 1 "$log32" | grep -q ' error ' && echo 0 || echo 1)"
else
  echo "skip 32 (running as root)"
fi

# 33: a newline in a value that reaches the log must not start a new record
log33="$tmp/state/log33"
DISK_HYGIENE_LOG="$log33" DISK_HYGIENE_FREE_GIB=500 run --apply
forged=$'/missing\n'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"' done repos=1 failed=0 x'
DISK_HYGIENE_LOG="$log33" DISK_HYGIENE_PRUNE="$forged" DISK_HYGIENE_FREE_GIB=500 run --apply
"$here/disk-hygiene-install" --verdict "$log33" > /dev/null 2>&1 && v33=0 || v33=1
check "33 a newline in an env value cannot forge a finish line" "$([[ "$v33" -eq 1 ]] && echo 0 || echo 1)"

# 34: a log the sweep cannot write. Nothing can be recorded, so it must at least fail out loud.
if [[ "$(id -u)" -ne 0 ]]; then
  log34="$tmp/state/log34"; : > "$log34"; chmod 400 "$log34"
  DISK_HYGIENE_LOG="$log34" DISK_HYGIENE_FREE_GIB=500 run --apply
  unwritable_rc="$(rc)"; chmod 644 "$log34"
  check "34 an unwritable log makes the sweep exit non-zero and say why" "$([[ "$unwritable_rc" -ne 0 ]] && grep -qi 'permission denied' "$tmp/out" && echo 0 || echo 1)"
else
  echo "skip 34 (running as root)"
fi

# 35: the installer truncates the launchd logs before bootstrap, so the job's open file stays the same
mkdir -p "$HOME/.local/state/disk-hygiene"
echo "stale error from an earlier run" > "$HOME/.local/state/disk-hygiene/launchd.err.log"
PATH="$tmp/unamebin:$PATH" LAUNCHCTL_MODE=ok LAUNCHCTL_APPEND_DONE=good DISK_HYGIENE_INSTALL_LOOPS=20 DISK_HYGIENE_INSTALL_POLL=0.1 \
  "$here/disk-hygiene-install" > "$tmp/i5.out" 2>&1 || true
errlog="$HOME/.local/state/disk-hygiene/launchd.err.log"
check "35 the launchd logs are truncated, not deleted" "$([[ -f "$errlog" && ! -s "$errlog" ]] && echo 0 || echo 1)"

# 36: the run id comes from the environment and reaches every record. One that carries fields must be
# refused, and the verdict must read the first repos= and failed= tokens, not a later injected one.
log36="$tmp/state/log36"
DISK_HYGIENE_LOG="$log36" DISK_HYGIENE_RUN_ID=' done repos=1 failed=0 x' DISK_HYGIENE_ROOTS="$tmp/rootEmpty" DISK_HYGIENE_FREE_GIB=500 run --apply
badid_rc="$(rc)"
"$here/disk-hygiene-install" --verdict "$log36" > /dev/null 2>&1 && v36=0 || v36=1
printf '%s done repos=0 swept=0 removed=0 needs_review=0 failed=0 caches_cleared=no free_before_gib=90 free_after_gib=90 run= done repos=1 failed=0 x\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/inject.log"
"$here/disk-hygiene-install" --verdict "$tmp/inject.log" > /dev/null 2>&1 && v36b=0 || v36b=1
check "36 a run id that carries fields is refused, and the first repos= token decides" "$([[ "$badid_rc" -eq 2 && "$v36" -eq 1 && "$v36b" -eq 1 ]] && echo 0 || echo 1)"

# 37: df answers with a normal table and then exits 1. The pipeline hid that failure, and errexit is off
# inside a function called through || die, so the sweep treated the table as a good reading.
mkdir -p "$tmp/dfbin2"
cat > "$tmp/dfbin2/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 976490576 1000 943718400 1%% /\n'
exit 1
STUB
chmod +x "$tmp/dfbin2/df"
log37="$tmp/state/log37"
PATH="$tmp/dfbin2:$PATH" DISK_HYGIENE_ROOTS="$tmp/rootEmpty" DISK_HYGIENE_LOG="$log37" DISK_HYGIENE_FREE_GIB='' run --apply
df37_rc="$(rc)"
check "37 df that prints a table and then fails is an error, status 2" "$([[ "$df37_rc" -eq 2 ]] && grep -q ' error ' "$log37" && echo 0 || echo 1)"

if [[ "$fails" -ne 0 ]]; then echo "--- last out"; cat "$tmp/out"; echo "$fails case(s) failed" >&2; exit 1; fi
echo "all cases passed"
