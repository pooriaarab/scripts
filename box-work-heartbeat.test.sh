#!/usr/bin/env bash
# Lifecycle tests for the box-work job-scoped heartbeat (issue 305).
# Offline: stub `box`, throwaway HOME/repo, bounded fake agents, no Boxes.
# Contract: a waiting worker gets periodic heartbeats; normal exit, failure,
# interruption and termination stop the helper with no orphans and preserve
# the worker status; the heartbeat then goes stale; the recorded Box id and
# the repository cwd stay intact.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${BOX_WORK_UNDER_TEST:-$DIR/box-work}"
PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

T=""
cleanup() {
  if [[ -n "$T" && -d "$T" ]]; then
    pkill -f "box-work-heartbeat-loop" 2>/dev/null || true
    pkill -f "$T/captured-runner.sh" 2>/dev/null || true
    rm -rf "$T"
  fi
  rm -rf /home/user/fakerepo
}
trap cleanup EXIT

mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
# The heartbeat helper execs into a `bash -c` carrying this marker, so this
# matches the helper loop only -- not the runner, its worker subshell, or an
# orphaned agent child, which share the runner script path in their cmdlines.
runner_live() { pgrep -f "box-work-heartbeat-loop" >/dev/null 2>&1; }

write_stub() {
  cat > "$T/stubbin/box" <<'STUB'
#!/usr/bin/env bash
T="${BOX_WORK_TEST_T:?}"
printf 'box %s\n' "$*" >>"$T/exec.log"
sub="${1:-}"; shift || true
case "$sub" in
  info) printf '{"box":{"state":"ready","url":"-"}}' ;;
  scp) cp "$1" "$T/captured-runner.sh" ;;
  exec)
    if [[ " $* " == *" --json "* ]]; then
      b64="${@: -1}"
      HOME="${BOX_WORK_TEST_BOX:?}" PATH="${BOX_WORK_TEST_BOX:?}/.local/bin:$PATH" \
        bash "$T/captured-runner.sh" "$b64" >"$T/runner.out" 2>"$T/runner.err"
      rc=$?
      python3 - "$T/runner.out" "$T/runner.err" "$rc" <<'PY'
import json,sys
print(json.dumps({"stdout": open(sys.argv[1]).read(),
                  "stderr": open(sys.argv[2]).read(),
                  "exitCode": int(sys.argv[3])}))
PY
    else
      exit 0
    fi
    ;;
  *) echo "stub box: unknown subcommand $sub" >&2; exit 99 ;;
esac
STUB
  chmod +x "$T/stubbin/box"
}

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/box-work-hb-test.XXXXXX")"
  FAKEHOME="$T/home"
  FAKEBOX="$T/boxhome"
  mkdir -p "$FAKEHOME/.agents" "$T/stubbin" "$T/xdg/box-work" \
    "$FAKEBOX/.agents" "$FAKEBOX/.local/bin" /home/user/fakerepo
  REPO="$T/repo"
  git init -q "$REPO" 2>/dev/null
  git -C "$REPO" remote add origin https://github.com/pooriaarab/fakerepo.git
  printf 'bx_test123\n' > "$T/xdg/box-work/fakerepo.id"
  : > "$T/exec.log"
  : > "$FAKEHOME/.agents/agent-clis.env"
  : > "$FAKEBOX/.agents/agent-clis.env"
  export BOX_WORK_TEST_T="$T" BOX_WORK_TEST_BOX="$FAKEBOX"
  write_stub
  cat > "$FAKEBOX/.local/bin/fake-agent" <<'FAKE'
#!/usr/bin/env bash
T="${BOX_WORK_TEST_T:?}"
echo "agent-invoke $(basename "$0") $*" >>"$T/calls.log"
case "${FAKE_AGENT_MODE:-ok}" in
  wait3) sleep 3; echo "AGENT-OUTPUT ${@: -1}" ;;
  wait30) trap 'exit 143' INT TERM; sleep 30 & wait $!; echo "AGENT-OUTPUT ${@: -1}" ;;
  fail3) sleep 1; echo "agent failed" >&2; exit 3 ;;
  *) echo "AGENT-OUTPUT ${@: -1}" ;;
esac
FAKE
  chmod +x "$FAKEBOX/.local/bin/fake-agent"
  for a in pi muse kimi codex gemini; do
    ln -sf fake-agent "$FAKEBOX/.local/bin/$a"
  done
}

# Run box-work in agent mode; result lands in $T/bw.{out,err,rc}.
run_agent() { # <agent> <brief>
  HOME="$FAKEHOME" XDG_STATE_HOME="$T/xdg" BOX_CLI="$T/stubbin/box" \
    BOX_WORK_HEARTBEAT_SECS=1 BOX_WORK_HEARTBEAT_FILE="$T/hb" \
    FAKE_AGENT_MODE="${FAKE_AGENT_MODE:-ok}" \
    bash "$SCRIPT" "$REPO" --agent "$1" "$2" >"$T/bw.out" 2>"$T/bw.err"
  printf '%s' "$?" >"$T/bw.rc"
}

setup

# 1. A waiting worker receives periodic heartbeats, and the full brief arrives.
FAKE_AGENT_MODE=wait3 run_agent pi "compute seventeen times twenty three" &
bgpid=$!
sleep 1.5; m1="$(mtime "$T/hb")"; sleep 1.5; m2="$(mtime "$T/hb")"
[ "$m2" -gt "$m1" ] \
  && pass "waiting worker receives periodic heartbeats" \
  || fail "waiting worker receives periodic heartbeats" "m1=$m1 m2=$m2"
wait "$bgpid"
[ "$(cat "$T/bw.rc")" = "0" ] \
  && pass "waiting worker exits 0" \
  || fail "waiting worker exits 0" "rc=$(cat "$T/bw.rc") err: $(cat "$T/bw.err")"
grep -q "seventeen times twenty three" "$T/bw.out" \
  && pass "multi-word brief arrives intact" \
  || fail "multi-word brief arrives intact" "$(cat "$T/bw.out")"

# 2. Normal exit stops the helper: no orphans, heartbeat goes stale.
runner_live \
  && fail "normal exit leaves no helper" "captured-runner.sh still alive" \
  || pass "normal exit leaves no helper"
m2b="$(mtime "$T/hb")"; sleep 2.5; m3="$(mtime "$T/hb")"
[ "$m3" = "$m2b" ] \
  && pass "heartbeat goes stale after exit" \
  || fail "heartbeat goes stale after exit" "m2b=$m2b m3=$m3"

# 3. Failure preserves the worker status and still cleans up.
FAKE_AGENT_MODE=fail3 run_agent pi "anything"
[ "$(cat "$T/bw.rc")" = "3" ] \
  && pass "agent failure exit code propagates" \
  || fail "agent failure exit code propagates" "rc=$(cat "$T/bw.rc") want 3"
runner_live \
  && fail "failure leaves no helper" "captured-runner.sh still alive" \
  || pass "failure leaves no helper"
m4="$(mtime "$T/hb")"; sleep 2.5
[ "$(mtime "$T/hb")" = "$m4" ] \
  && pass "heartbeat goes stale after failure" \
  || fail "heartbeat goes stale after failure" "mtime kept moving"

# 4. Termination kills the whole job: no success masquerade, no orphans.
export HOME="$FAKEHOME" XDG_STATE_HOME="$T/xdg" BOX_CLI="$T/stubbin/box" \
  FAKE_AGENT_MODE=wait30
export BOX_WORK_HEARTBEAT_SECS=1 BOX_WORK_HEARTBEAT_FILE="$T/hb-term"
setsid bash "$SCRIPT" "$REPO" --agent pi "long job" >"$T/bw.out" 2>"$T/bw.err" &
bgpid=$!
sleep 2
[ -f "$T/hb-term" ] \
  && pass "terminated job had a live heartbeat first" \
  || fail "terminated job had a live heartbeat first" "no hb-term file"
kill -TERM -"$bgpid"
wait "$bgpid"; trc=$?
[ "$trc" != "0" ] \
  && pass "termination does not report success (rc=$trc)" \
  || fail "termination does not report success" "rc=0"
runner_live \
  && fail "termination leaves no helper" "captured-runner.sh still alive" \
  || pass "termination leaves no helper"
m5="$(mtime "$T/hb-term")"; sleep 2.5
[ "$(mtime "$T/hb-term")" = "$m5" ] \
  && pass "heartbeat goes stale after termination" \
  || fail "heartbeat goes stale after termination" "mtime kept moving"
unset FAKE_AGENT_MODE BOX_WORK_HEARTBEAT_SECS BOX_WORK_HEARTBEAT_FILE

# 5. The generated runner targets the recorded Box with the repo cwd baked in.
grep -q "bx_test123" "$T/exec.log" \
  && pass "dispatch targets the recorded Box id" \
  || fail "dispatch targets the recorded Box id" "$(cat "$T/exec.log")"
grep -q "bash /home/user/box-work-run.sh" "$T/exec.log" \
  && pass "dispatch runs the uploaded runner script" \
  || fail "dispatch runs the uploaded runner script" "$(cat "$T/exec.log")"
grep -qF 'cd "/home/user/fakerepo"' "$T/captured-runner.sh" \
  && pass "runner keeps the explicit repository cwd" \
  || fail "runner keeps the explicit repository cwd" "cd line missing"
grep -qF "HEARTBEAT_SECS=\"1\"" "$T/captured-runner.sh" \
  && pass "heartbeat interval is baked into the runner" \
  || fail "heartbeat interval is baked into the runner" "interval not baked"

# 6. Even an uncatchable kill stops the heartbeat: the helper exits on its own
# once its parent is gone. (A PID-only SIGKILL can still strand the worker
# subshell itself -- no shell can trap SIGKILL -- but the stranded worker no
# longer beats the heartbeat, so the reaper exemption ends with the job.)
b64="$(printf '%s' "probe" | base64 | tr -d '\n')"
FAKE_AGENT_MODE=wait30 HOME="$FAKEBOX" PATH="$FAKEBOX/.local/bin:$PATH" \
  bash "$T/captured-runner.sh" "$b64" >"$T/direct.out" 2>"$T/direct.err" &
rpid=$!
sleep 2
kill -KILL "$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null || true
sleep 3
runner_live \
  && fail "SIGKILL leaves no helper" "captured-runner.sh still alive" \
  || pass "SIGKILL leaves no helper"
m6="$(mtime "$T/hb-term")"; sleep 2.2
[ "$(mtime "$T/hb-term")" = "$m6" ] \
  && pass "heartbeat goes stale after SIGKILL" \
  || fail "heartbeat goes stale after SIGKILL" "mtime kept moving"

# 7. A foreground SIGINT is answered promptly with status 130. `timeout`
# delivers INT to a foreground runner -- the honest harness, because a `&`
# background job inherits SIGINT ignored and no shell can trap that, while
# `box exec` runs the real job in the foreground. `--preserve-status` keeps
# the runner's own status: bare `timeout` reports 124 whenever it fires, even
# when the child died correctly, which would mask a real 130 as a failure.
b64="$(printf '%s' "trap probe" | base64 | tr -d '\n')"
FAKE_AGENT_MODE=wait30 HOME="$FAKEBOX" PATH="$FAKEBOX/.local/bin:$PATH" \
  timeout --preserve-status -s INT 4 bash "$T/captured-runner.sh" "$b64" >"$T/int.out" 2>"$T/int.err"
irc=$?
[ "$irc" = "130" ] \
  && pass "foreground SIGINT reports 130" \
  || fail "foreground SIGINT reports 130" "rc=$irc"
runner_live \
  && fail "SIGINT leaves no helper" "captured-runner.sh still alive" \
  || pass "SIGINT leaves no helper"
m7="$(mtime "$T/hb-term")"; sleep 2.2
[ "$(mtime "$T/hb-term")" = "$m7" ] \
  && pass "heartbeat goes stale after SIGINT" \
  || fail "heartbeat goes stale after SIGINT" "mtime kept moving"

FAKE_AGENT_MODE=wait30 HOME="$FAKEBOX" PATH="$FAKEBOX/.local/bin:$PATH" \
  bash "$T/captured-runner.sh" "$b64" >"$T/term.out" 2>"$T/term.err" &
rpid=$!
sleep 2
kill -TERM "$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null; trc2=$?
[ "$trc2" = "143" ] \
  && pass "SIGTERM to the runner reports 143" \
  || fail "SIGTERM to the runner reports 143" "rc=$trc2"
runner_live \
  && fail "SIGTERM leaves no helper" "captured-runner.sh still alive" \
  || pass "SIGTERM leaves no helper"

# 8. The interval guard in the shipped runner resets bad values to 30s.
guard="$(grep -F 'HEARTBEAT_SECS=30 ;; esac' "$T/captured-runner.sh")"
[ -n "$guard" ] \
  && pass "runner carries the interval guard" \
  || fail "runner carries the interval guard" "guard line missing"
bad=0
for v in "" 0 abc; do
  got="$(HEARTBEAT_SECS="$v"; eval "$guard"; printf '%s' "$HEARTBEAT_SECS")"
  [ "$got" = "30" ] || bad=1
done
[ "$bad" = "0" ] \
  && pass "bad intervals fall back to 30s" \
  || fail "bad intervals fall back to 30s" "guard let one through"
got="$(HEARTBEAT_SECS=5; eval "$guard"; printf '%s' "$HEARTBEAT_SECS")"
[ "$got" = "5" ] \
  && pass "a valid interval is kept" \
  || fail "a valid interval is kept" "got $got"

# 9. An unwritable heartbeat file warns loudly but does not fail the job.
HOME="$FAKEHOME" XDG_STATE_HOME="$T/xdg" BOX_CLI="$T/stubbin/box" \
  BOX_WORK_HEARTBEAT_SECS=1 BOX_WORK_HEARTBEAT_FILE="$T/no-such-dir/hb" \
  FAKE_AGENT_MODE=ok \
  bash "$SCRIPT" "$REPO" --agent pi "anything" >"$T/bw.out" 2>"$T/bw.err"
rc9=$?
[ "$rc9" = "0" ] \
  && pass "unwritable heartbeat still runs the job" \
  || fail "unwritable heartbeat still runs the job" "rc=$rc9 err: $(cat "$T/bw.err")"
grep -q "idle-reaper exemption inactive" "$T/bw.err" \
  && pass "unwritable heartbeat warns on stderr" \
  || fail "unwritable heartbeat warns on stderr" "$(cat "$T/bw.err")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
