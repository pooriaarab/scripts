#!/usr/bin/env bash
# Tests for box-work startup retry, explicit cwd, credential export, agent
# dispatch, and failure propagation. Offline: stub BOX_CLI, fake agent CLIs,
# generated runner executes locally. No Box is created; no secrets anywhere.
# Override under test: BOX_WORK_UNDER_TEST=/tmp/mutant bash box-work.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${BOX_WORK_UNDER_TEST:-$DIR/box-work}"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rmdir /home/user/fakerepo 2>/dev/null || true
  return 0
}
trap cleanup EXIT

newtd() {
  mktemp -d "${TMPDIR:-/tmp}/box-work-test.XXXXXX"
}

T=""
FAKEHOME=""
REPO=""

write_stub() {
  cat > "$T/stubbin/box" <<'STUB'
#!/usr/bin/env bash
T="${BOX_WORK_TEST_T:?}"
sub="${1:-}"; shift || true
case "$sub" in
  info) printf '{"box":{"state":"ready","url":"https://example.invalid/x"}}\n' ;;
  new) touch "$T/new-called"; echo "stub box: new must not be called" >&2; exit 99 ;;
  scp) cp "$1" "$T/captured-runner.sh" ;;
  exec)
    printf '%s\n' "$*" >>"$T/exec.log"
    after=0; cmd=()
    for a in "$@"; do
      if (( after )); then cmd+=("$a"); continue; fi
      if [[ "$a" == "--" ]]; then after=1; fi
    done
    if [[ "${cmd[0]:-}" == "true" ]]; then
      n="$(cat "$T/probe_fails")"
      if (( n > 0 )); then
        printf '%s' "$((n-1))" >"$T/probe_fails"
        echo '{"error":"box_starting"}' >&2; exit 1
      fi
      exit 0
    fi
    b64="${cmd[${#cmd[@]}-1]}"
    HOME="$T/home" PATH="/usr/bin:/bin" \
      bash "$T/captured-runner.sh" "$b64" >"$T/runner.out" 2>"$T/runner.err"
    rc=$?
    python3 - "$T/runner.out" "$T/runner.err" "$rc" <<'PY'
import json,sys
o=open(sys.argv[1]).read(); e=open(sys.argv[2]).read(); rc=int(sys.argv[3])
print(json.dumps({"stdout":o,"stderr":e,"exitCode":rc}))
PY
    ;;
  *) echo "stub box: unknown subcommand $sub" >&2; exit 99 ;;
esac
STUB
  chmod +x "$T/stubbin/box"
}

write_fake() { # <name> <body...>: body via stdin
  cat > "$FAKEHOME/.local/bin/$1"
  chmod +x "$FAKEHOME/.local/bin/$1"
}

setup() {
  T=$(newtd)
  TMPDIRS+=("$T")
  FAKEHOME="$T/home"
  mkdir -p "$FAKEHOME/.agents" "$FAKEHOME/.local/bin" "$T/stubbin" "$T/xdg/box-work"
  REPO="$T/repo"
  git init -q "$REPO" 2>/dev/null
  git -C "$REPO" remote add origin https://github.com/pooriaarab/fakerepo.git
  mkdir -p /home/user/fakerepo
  printf 'bx_test123\n' > "$T/xdg/box-work/fakerepo.id"
  printf '0' > "$T/probe_fails"
  : > "$T/exec.log"
  # Fake roster value; never a real secret. Cursor's key lives in cursor.env.
  printf 'GEMINI_API_KEY=test-fixture-no-secret\n' > "$FAKEHOME/.agents/agent-clis.env"
  export BOX_WORK_TEST_T="$T"
  write_stub
  write_fake cursor-agent <<'FAKE'
#!/usr/bin/env bash
echo "cursor-agent $*" >>"$BOX_WORK_TEST_T/calls.log"
if [[ -n "${FAKE_AGENT_EXIT:-}" && "${FAKE_AGENT_EXIT}" != "0" ]]; then exit "$FAKE_AGENT_EXIT"; fi
if [[ -z "${CURSOR_API_KEY:-}" ]]; then echo "CURSOR_API_KEY missing" >&2; exit 1; fi
echo "CURSOR-OK $*"
FAKE
  write_fake muse <<'FAKE'
#!/usr/bin/env bash
echo "muse $*" >>"$BOX_WORK_TEST_T/calls.log"
[[ " $* " == *" --yolo "* ]] || { echo "muse: missing --yolo" >&2; exit 1; }
[[ " $* " == *" --prompt-file "* ]] || { echo "muse: missing --prompt-file" >&2; exit 1; }
pf=""; prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && pf="$a"; prev="$a"; done
[[ -n "$pf" ]] || { echo "muse: empty prompt file" >&2; exit 1; }
cat "$pf"
FAKE
  write_fake devin <<'FAKE'
#!/usr/bin/env bash
echo "devin $*" >>"$BOX_WORK_TEST_T/calls.log"
if [[ "${BOX_WORK_DEVIN_AUTH:-personal}" == "personal" ]]; then
  if [[ -n "${DEVIN_API_KEY+set}" || -n "${DEVIN_TOKEN+set}" || -n "${WINDSURF_API_KEY+set}" ]]; then
    echo "devin: API env leaked into personal route" >&2; exit 1
  fi
else
  [[ -n "${DEVIN_API_KEY:-}" ]] || { echo "devin: api route without key" >&2; exit 1; }
fi
for f in --model --respect-workspace-trust --permission-mode -p; do
  [[ " $* " == *" $f "* ]] || { echo "devin: missing $f" >&2; exit 1; }
done
pf=""; prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && pf="$a"; prev="$a"; done
[[ -n "$pf" ]] || { echo "devin: missing --prompt-file" >&2; exit 1; }
cat "$pf"
FAKE
  write_fake gemini <<'FAKE'
#!/usr/bin/env bash
echo "gemini $*" >>"$BOX_WORK_TEST_T/calls.log"
[[ "${GEMINI_CLI_HOME:-}" == "$HOME/.gemini-personal" ]] || { echo "gemini: wrong GEMINI_CLI_HOME" >&2; exit 1; }
if [[ -n "${GOOGLE_GENAI_USE_VERTEXAI+set}" || -n "${GOOGLE_APPLICATION_CREDENTIALS+set}" ]]; then
  echo "gemini: Vertex env leaked" >&2; exit 1
fi
[[ -n "${GEMINI_API_KEY:-}" ]] || { echo "gemini: missing key" >&2; exit 1; }
for f in --skip-trust --yolo -p; do
  [[ " $* " == *" $f "* ]] || { echo "gemini: missing $f" >&2; exit 1; }
done
echo "GEMINI-OK $*"
FAKE
}

# Run box-work in agent mode; result lands in $T/bw.{out,err,rc}.
run_agent() { # <agent> <brief>
  HOME="$FAKEHOME" XDG_STATE_HOME="$T/xdg" BOX_CLI="$T/stubbin/box" \
    BOX_WORK_READY_SECS="${BOX_WORK_READY_SECS:-60}" \
    bash "$SCRIPT" "$REPO" --agent "$1" "$2" >"$T/bw.out" 2>"$T/bw.err"
  printf '%s' "$?" >"$T/bw.rc"
}

# --- cases ---

setup
printf 'CURSOR_API_KEY=test-fixture-no-secret\n' > "$FAKEHOME/.agents/cursor.env"
printf '2' > "$T/probe_fails"
run_agent cursor "compute seventeen times twenty three"
rc="$(cat "$T/bw.rc")"
[ "$rc" = "0" ] || fail "transient startup retried to success" "rc=$rc err: $(cat "$T/bw.err")"
[ "$rc" = "0" ] && pass "transient startup retried to success"
grep -qF -- '--cwd /home/user' "$T/exec.log" \
  && pass "readiness probes from explicit --cwd /home/user" \
  || fail "readiness probes from explicit --cwd /home/user" "$(cat "$T/exec.log")"
[ "$(grep -cF -- '-- true' "$T/exec.log")" = "3" ] \
  && pass "readiness retried twice before succeeding" \
  || fail "readiness retried twice before succeeding" "$(cat "$T/exec.log")"
[ ! -e "$T/new-called" ] \
  && pass "recorded Box reused, no replacement created" \
  || fail "recorded Box reused, no replacement created" "stub box new ran"
grep -q "CURSOR-OK" "$T/bw.out" \
  && pass "cursor dispatched with exported key" \
  || fail "cursor dispatched with exported key" "$(cat "$T/bw.out") $(cat "$T/bw.err")"
for flag in "--trust" "--force" "--model composer-2.5" "--output-format json"; do
  grep -qF -- "$flag" "$T/calls.log" \
    && pass "cursor headless flag: $flag" \
    || fail "cursor headless flag: $flag" "$(cat "$T/calls.log")"
done
grep -qF "seventeen times twenty three" "$T/bw.out" \
  && pass "multi-word brief arrives intact" \
  || fail "multi-word brief arrives intact" "$(cat "$T/bw.out")"

run_agent muse "say the word banana bread loudly"
rc="$(cat "$T/bw.rc")"
[ "$rc" = "0" ] || fail "muse headless dispatch succeeds" "rc=$rc err: $(cat "$T/bw.err")"
[ "$rc" = "0" ] && pass "muse headless dispatch succeeds"
grep -q "banana bread loudly" "$T/bw.out" \
  && pass "muse receives full brief via prompt file" \
  || fail "muse receives full brief via prompt file" "$(cat "$T/bw.out")"
grep -qF -- "--workspace /home/user/fakerepo" "$T/calls.log" \
  && pass "muse runs in the explicit repository path" \
  || fail "muse runs in the explicit repository path" "$(cat "$T/calls.log")"

DEVIN_API_KEY=should-be-scrubbed DEVIN_TOKEN=should-be-scrubbed WINDSURF_API_KEY=should-be-scrubbed \
  run_agent devin "report the number after six"
rc="$(cat "$T/bw.rc")"
[ "$rc" = "0" ] || fail "devin personal route succeeds" "rc=$rc err: $(cat "$T/bw.err")"
[ "$rc" = "0" ] && pass "devin personal route succeeds"
grep -q "the number after six" "$T/bw.out" \
  && pass "devin personal route scrubs API env and runs" \
  || fail "devin personal route scrubs API env and runs" "$(cat "$T/bw.out") $(cat "$T/bw.err")"
# Prefix assignments on a function call persist: scrub them so later cases
# start from a clean environment.
unset DEVIN_API_KEY DEVIN_TOKEN WINDSURF_API_KEY

BOX_WORK_DEVIN_AUTH=bogus run_agent devin "anything"
[ "$(cat "$T/bw.rc")" != "0" ] \
  && pass "unknown devin auth route fails loudly" \
  || fail "unknown devin auth route fails loudly" "rc=0 unexpectedly"
grep -q "BOX_WORK_DEVIN_AUTH" "$T/bw.err" \
  && pass "unknown devin auth route names the knob" \
  || fail "unknown devin auth route names the knob" "$(cat "$T/bw.err")"

BOX_WORK_DEVIN_AUTH=api run_agent devin "anything"
[ "$(cat "$T/bw.rc")" != "0" ] \
  && pass "devin api route without key fails loudly" \
  || fail "devin api route without key fails loudly" "rc=0 unexpectedly"
grep -q "devin.env" "$T/bw.err" \
  && pass "devin api failure names the credential file" \
  || fail "devin api failure names the credential file" "$(cat "$T/bw.err")"
unset BOX_WORK_DEVIN_AUTH

run_agent gemini "name a green fruit"
rc="$(cat "$T/bw.rc")"
[ "$rc" = "0" ] || fail "gemini dispatched with personal env" "rc=$rc err: $(cat "$T/bw.err")"
[ "$rc" = "0" ] && pass "gemini dispatched with personal env"
for flag in "--skip-trust" "--yolo" "-m gemini-3.8-flash"; do
  grep -qF -- "$flag" "$T/calls.log" \
    && pass "gemini headless flag: $flag" \
    || fail "gemini headless flag: $flag" "$(cat "$T/calls.log")"
done

rm -f "$FAKEHOME/.agents/cursor.env"
run_agent cursor "anything"
[ "$(cat "$T/bw.rc")" != "0" ] \
  && pass "missing cursor key fails loudly" \
  || fail "missing cursor key fails loudly" "rc=0 unexpectedly"
grep -q "cursor.env" "$T/bw.err" \
  && pass "missing cursor key names the credential file" \
  || fail "missing cursor key names the credential file" "$(cat "$T/bw.err")"
before_cursors=$(grep -c "cursor-agent" "$T/calls.log" 2>/dev/null || true)
[ "$before_cursors" = "1" ] \
  && pass "missing cursor key never invokes the CLI" \
  || fail "missing cursor key never invokes the CLI" "cursor-agent lines: $before_cursors"

printf 'CURSOR_API_KEY=test-fixture-no-secret\n' > "$FAKEHOME/.agents/cursor.env"
FAKE_AGENT_EXIT=3 run_agent cursor "anything"
[ "$(cat "$T/bw.rc")" = "3" ] \
  && pass "agent failure exit code propagates" \
  || fail "agent failure exit code propagates" "rc=$(cat "$T/bw.rc") want 3"
unset FAKE_AGENT_EXIT

printf '999' > "$T/probe_fails"
SEC_START="$SECONDS"
BOX_WORK_READY_SECS=6 run_agent cursor "anything"
unset BOX_WORK_READY_SECS
elapsed=$((SECONDS - SEC_START))
[ "$(cat "$T/bw.rc")" != "0" ] \
  && pass "unready Box fails instead of hanging" \
  || fail "unready Box fails instead of hanging" "rc=0 unexpectedly"
grep -q "never answered within" "$T/bw.err" \
  && pass "unready Box names the bounded deadline" \
  || fail "unready Box names the bounded deadline" "$(cat "$T/bw.err")"
[ "$elapsed" -lt 25 ] \
  && pass "readiness wait is bounded (${elapsed}s)" \
  || fail "readiness wait is bounded (${elapsed}s)" "took too long"

echo "---"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
