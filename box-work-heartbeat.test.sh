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
    pkill -f "$T/captured-runner.sh" 2>/dev/null || true
    rm -rf "$T"
  fi
  rm -rf /home/user/fakerepo
}
trap cleanup EXIT

mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
runner_live() { pgrep -f "$T/captured-runner.sh" >/dev/null 2>&1; }

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

# 6. Even an uncatchable kill leaves no orphan: the helper exits on its own.
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

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
