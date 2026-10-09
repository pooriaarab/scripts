#!/usr/bin/env bash
# Tests for amo-sign-retry. Each row of amo-sign-retry.failure-modes.md that
# is marked "tested" has a case here. A stub `gh` serves canned run states
# from files, so nothing leaves the host and no test waits.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/stub"
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
# State per repo NAME: NAME.run (newest run line), NAME.step (sign step
# conclusion), NAME.log (failed log), NAME.after (run line after a rerun),
# NAME.next (run line after an in-progress poll).
printf '%s\n' "$*" >> "$GH_LOG"
name() { printf '%s' "$1" | sed -E 's#.*repos/[^/]+/([^/]+)/.*#\1#'; }
case "$*" in
  *"/actions/workflows/"*) n=$(name "$2"); cat "$STUB/$n.run" 2>/dev/null
    # A run in progress finishes on the next poll when NAME.next exists.
    grep -q in_progress "$STUB/$n.run" 2>/dev/null && [ -f "$STUB/$n.next" ] && mv "$STUB/$n.next" "$STUB/$n.run" ;;
  *"/actions/runs/"*"/jobs"*) n=$(name "$2"); cat "$STUB/$n.step" ;;
  "run view"*) n=${5#*/}; cat "$STUB/$n.log" ;;
  "run rerun"*) n=${5#*/}; [ -f "$STUB/$n.after" ] && mv "$STUB/$n.after" "$STUB/$n.run" ;;
esac
exit 0
EOF
chmod +x "$d/bin/gh"
export PATH="$d/bin:$SCRIPT_DIR:$PATH"
export GH_LOG="$d/gh.log" STUB="$d/stub"
export AMO_SIGN_RETRY_SLEEP=true AMO_SIGN_RETRY_SETTLE=0
past="2020-01-01T00:00:00Z"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
S="$d/stub"
retry() { amo-sign-retry --margin 0 --interval 0 "$@"; }

# 1: usage.
amo-sign-retry >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "no repo exits 1" || fail_msg "no repo (rc $rc)"
amo-sign-retry just-a-name >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "repo without owner exits 1" || fail_msg "bad repo (rc $rc)"

# 2: no runs.
: > "$S/none.run"
out=$(retry o/none 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "o/none: no run" && ok "no run counts as a failure" || fail_msg "no run (rc $rc): $out"

# 4: signed.
echo "1 completed success $past" > "$S/done.run"
out=$(retry o/done 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "o/done: signed" && ok "a green run reports signed" || fail_msg "signed (rc $rc): $out"

# 5: failed before signing.
echo "3 completed failure $past" > "$S/early.run"; echo skipped > "$S/early.step"
: > "$GH_LOG"
out=$(retry o/early 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "before signing" && ! grep -q "run rerun" "$GH_LOG" \
  && ok "a failure before signing is not re-run" || fail_msg "early (rc $rc): $out"

# 6: signing failed, not a throttle.
echo "4 completed failure $past" > "$S/other.run"; echo failure > "$S/other.step"
echo "Error: invalid manifest" > "$S/other.log"
: > "$GH_LOG"
out=$(retry o/other 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "not a throttle" && ! grep -q "run rerun" "$GH_LOG" \
  && ok "a signing failure without a window is not re-run" || fail_msg "other (rc $rc): $out"

# 7 + 3: throttled, re-run once, then the re-run is in progress, then signed.
echo "5 completed failure $past" > "$S/slow.run"; echo failure > "$S/slow.step"
echo "Expected available in 5 seconds" > "$S/slow.log"
echo "5 in_progress null $past" > "$S/slow.after"
: > "$GH_LOG"
echo "5 completed success $past" > "$S/slow.next"
out=$(retry o/slow 2>&1); rc=$?
reruns=$(grep -c "run rerun 5 -R o/slow --failed" "$GH_LOG")
[ "$rc" -eq 0 ] && [ "$reruns" = 1 ] && echo "$out" | grep -q "o/slow: signed" \
  && ok "a throttled run is re-run once and then reports signed" || fail_msg "throttle (rc $rc, reruns $reruns): $out"

# 8: endless throttle stops at --max-attempts.
echo "6 completed failure $past" > "$S/stuck.run"; echo failure > "$S/stuck.step"
echo "Expected available in 9 seconds" > "$S/stuck.log"
: > "$GH_LOG"
out=$(retry --max-attempts 2 o/stuck 2>&1); rc=$?
reruns=$(grep -c "run rerun 6" "$GH_LOG")
[ "$rc" -eq 1 ] && [ "$reruns" = 2 ] && echo "$out" | grep -q "gave up" \
  && ok "an endless throttle stops after --max-attempts" || fail_msg "max attempts (rc $rc, reruns $reruns): $out"

# 10: --once with a window that has not passed: no rerun, no sleep, exit 3.
echo "7 completed failure $now" > "$S/wait.run"; echo failure > "$S/wait.step"
echo "Expected available in 4000 seconds" > "$S/wait.log"
: > "$GH_LOG"
out=$(AMO_SIGN_RETRY_SLEEP=false retry --once o/wait 2>&1); rc=$?
[ "$rc" -eq 3 ] && ! grep -q "run rerun" "$GH_LOG" && echo "$out" | grep -q "o/wait: throttled" \
  && ok "--once leaves a future window alone and exits 3" || fail_msg "once future (rc $rc): $out"

# 10: --once with a passed window re-runs and exits 3.
: > "$GH_LOG"
echo "8 completed failure $past" > "$S/slow2.run"; echo failure > "$S/slow2.step"
echo "Expected available in 5 seconds" > "$S/slow2.log"
: > "$GH_LOG"
out=$(AMO_SIGN_RETRY_SLEEP=false retry --once o/slow2 2>&1); rc=$?
[ "$rc" -eq 3 ] && grep -q "run rerun 8 -R o/slow2 --failed" "$GH_LOG" \
  && ok "--once re-runs a passed window and exits 3" || fail_msg "once past (rc $rc): $out"

# 3: --once with a run in progress exits 3.
echo "9 in_progress null $past" > "$S/busy.run"
out=$(AMO_SIGN_RETRY_SLEEP=false retry --once o/busy 2>&1); rc=$?
[ "$rc" -eq 3 ] && echo "$out" | grep -q "o/busy: running" && ok "--once reports a running workflow and exits 3" || fail_msg "once busy (rc $rc): $out"

# Mixed repos: one hard failure makes the exit 1 even when another signs.
out=$(retry o/done o/other 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "o/done: signed" && ok "one failure among several repos exits 1" || fail_msg "mixed (rc $rc): $out"

echo "# pass $pass fail $fail"
[ "$fail" -eq 0 ]
