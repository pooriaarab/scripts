#!/usr/bin/env bash
# Tests for box-provider-readiness. Offline: stub BOX_CLI, fixture HOME with a
# fake muse, generated probe runner executes locally. The tests drive the REAL
# helper and gate a REAL sentinel (touch); no test greps the helper's source.
# No Box is created; credential values are fixtures and must never appear in
# helper output.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${BOX_READINESS_UNDER_TEST:-$DIR/box-provider-readiness}"
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }
cleanup() { rm -rf "${T:-}"; }
trap cleanup EXIT

write_stub() {
  cat > "$T/stubbin/box" <<'STUB'
#!/usr/bin/env bash
T="${READINESS_TEST_T:?}"
sub="${1:-}"; shift || true
case "$sub" in
  new) touch "$T/new-called"; echo "stub box: new must not be called" >&2; exit 99 ;;
  scp) dest="${2#*:}"; cp "$1" "$dest" ;; # dest is already under $T (BOX_PROBE_BASE)
  exec)
    printf '%s\n' "$*" >>"$T/exec.log"
    after=0; cmd=()
    for a in "$@"; do
      if (( after )); then cmd+=("$a"); continue; fi
      if [[ "$a" == "--" ]]; then after=1; fi
    done
    jout() { python3 -c 'import json,sys; print(json.dumps({"stdout":open(sys.argv[1]).read(),"stderr":open(sys.argv[2]).read(),"exitCode":int(sys.argv[3])}))' "$1" "$2" "$3"; }
    case "${cmd[0]:-}" in
      true)
        n="$(cat "$T/probe_fails")"
        if (( n > 0 )); then printf '%s' "$((n-1))" >"$T/probe_fails"; echo '{"error":"box_starting"}' >&2; exit 1; fi
        exit 0 ;;
      command)
        if [[ -f "$T/no-binary" ]]; then printf '{"stdout":"","stderr":"","exitCode":1}\n'; else printf '{"stdout":"/home/user/.local/bin/muse","stderr":"","exitCode":0}\n'; fi ;;
      test)
        if [[ -f "$T/no-cred" ]]; then printf '{"stdout":"","stderr":"","exitCode":1}\n'; else printf '{"stdout":"","stderr":"","exitCode":0}\n'; fi ;;
      mktemp) d="$(mktemp -d "${cmd[2]}")"; o="$(mktemp)"; printf '%s\n' "$d" >"$o"; e="$(mktemp)"; : >"$e"; jout "$o" "$e" 0 ;;
      bash)
        if [[ -f "$T/timeout" ]]; then echo "box: exec timed out after 30s" >&2; exit 124; fi
        env -i HOME="$T/home" PATH="$T/home/.local/bin:/usr/bin:/bin" READINESS_TEST_T="$T" \
          bash "${cmd[1]}" "${cmd[2]}" >"$T/probe.out" 2>"$T/probe.err"; jout "$T/probe.out" "$T/probe.err" "$?" ;;
      cat) o="$(mktemp)"; e="$(mktemp)"; "${cmd[@]}" >"$o" 2>"$e"; rc=$?; jout "$o" "$e" "$rc" ;;
      rm) "${cmd[@]}" >/dev/null 2>&1; printf '{"stdout":"","stderr":"","exitCode":0}\n' ;;
      *) echo "stub box exec: unknown: ${cmd[*]}" >&2; exit 99 ;;
    esac
    ;;
  *) echo "stub box: unknown subcommand $sub" >&2; exit 99 ;;
esac
STUB
  chmod +x "$T/stubbin/box"
}

setup() { # [fixture-flags...]: fresh T per test
  T="$(mktemp -d "${TMPDIR:-/tmp}/box-readiness-test.XXXXXX")"
  mkdir -p "$T/stubbin" "$T/home/.config/muse" "$T/home/.local/bin"
  printf '{"fixture":"test-fixture-no-secret"}\n' > "$T/home/.config/muse/auth.json"
  printf '0' > "$T/probe_fails"
  : > "$T/exec.log"
  export READINESS_TEST_T="$T"
  write_stub
  cat > "$T/home/.local/bin/muse" <<'FAKE'
#!/usr/bin/env bash
echo "muse $*" >>"$READINESS_TEST_T/calls.log"
[[ " $* " == *" --yolo "* ]] || { echo "muse: missing --yolo" >&2; exit 1; }
[[ " $* " == *" --model muse-spark-1.3-contributor "* ]] || { echo "muse: wrong model route" >&2; exit 1; }
[[ " $* " == *" --prompt-file "* && " $* " == *" --workspace "* ]] || { echo "muse: missing --prompt-file/--workspace" >&2; exit 1; }
pf=""; prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && pf="$a"; prev="$a"; done
prompt="$(cat "$pf")"
[[ "$prompt" =~ ([0-9]+)\*([0-9]+) ]] || { echo "muse: no arithmetic in prompt" >&2; exit 1; }
prod=$((BASH_REMATCH[1] * BASH_REMATCH[2]))
[[ "$prompt" =~ to\ ([^[:space:]]+/result\.txt) ]] || { echo "muse: no result file in prompt" >&2; exit 1; }
res="${BASH_REMATCH[1]}"
if [[ -f "$READINESS_TEST_T/auth-fail" ]]; then
  echo "muse: Authentication required (test-fixture). MUSE_API_KEY=fake-leak-999" >&2; exit 1
fi
if [[ -f "$READINESS_TEST_T/wrong-write" ]]; then printf '%s\n' "$prod" | tail -1; printf '%s\n' "$((prod+1))" >"$res"; exit 0; fi
printf '%s\n' "$prod" >"$res"; printf '%s\n' "$prod"
FAKE
  chmod +x "$T/home/.local/bin/muse"
}

run_helper() { # extra helper args, then sentinel argv after --
  out=$( BOX_CLI="$T/stubbin/box" BOX_PROBE_BASE="$T/home" \
    "$SCRIPT" --box bx_test123 --provider muse --cwd /home/user/fakerepo \
      --ready-secs 30 --timeout 30 "$@" 2>&1 )
  rc=$?
}

sentinel_unreached() { [[ ! -e "$T/sentinel" ]]; }

test_fresh_success() {
  setup
  run_helper -- touch "$T/sentinel"
  if (( rc == 0 )) && [[ -e "$T/sentinel" ]] && echo "$out" | grep -q "READY box=bx_test123 provider=muse" \
    && ! echo "$out" | grep -q "test-fixture-no-secret"; then
    pass "fresh box: valid probe reaches the sentinel, no credential values logged"
  else
    fail "fresh box: valid probe reaches the sentinel" "rc=$rc out=$out"
  fi
}

test_resumed_transient_success() {
  setup
  printf '2' > "$T/probe_fails"
  run_helper -- touch "$T/sentinel"
  if (( rc == 0 )) && [[ -e "$T/sentinel" ]] && [[ ! -e "$T/new-called" ]]; then
    pass "resumed box: transient startup reuses the recorded id, no duplicate created"
  else
    fail "resumed box: transient startup reuses the recorded id" "rc=$rc out=$out"
  fi
}

test_missing_binary() {
  setup
  touch "$T/no-binary"
  run_helper -- touch "$T/sentinel"
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "binary 'muse' not found"; then
    pass "missing binary fails before the sentinel"
  else
    fail "missing binary fails before the sentinel" "rc=$rc out=$out"
  fi
}

test_missing_credential() {
  setup
  touch "$T/no-cred"
  run_helper -- touch "$T/sentinel"
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "canonical credential.*missing or empty" \
    && ! echo "$out" | grep -q "test-fixture-no-secret"; then
    pass "missing credential fails explicitly with no fallback and no values logged"
  else
    fail "missing credential fails explicitly" "rc=$rc out=$out"
  fi
}

test_invalid_auth() {
  setup
  touch "$T/auth-fail"
  run_helper -- touch "$T/sentinel"
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "provider bootstrap" \
    && ! echo "$out" | grep -q "fake-leak-999" && echo "$out" | grep -q "redacted"; then
    pass "invalid auth fails with sanitized output and the sentinel unreached"
  else
    fail "invalid auth fails sanitized" "rc=$rc out=$out"
  fi
}

test_wrong_write() {
  setup
  touch "$T/wrong-write"
  run_helper -- touch "$T/sentinel"
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "wrote.*expected"; then
    pass "wrong probe file fails before the sentinel"
  else
    fail "wrong probe file fails before the sentinel" "rc=$rc out=$out"
  fi
}

test_timeout() {
  setup
  touch "$T/timeout"
  run_helper -- touch "$T/sentinel"
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "failed before returning"; then
    pass "probe timeout fails before the sentinel"
  else
    fail "probe timeout fails before the sentinel" "rc=$rc out=$out"
  fi
}

test_wrong_model() {
  setup
  out=$( BOX_CLI="$T/stubbin/box" BOX_PROBE_BASE="$T/home" \
    "$SCRIPT" --box bx_test123 --provider muse --model wrong-model --cwd /home/user/fakerepo -- touch "$T/sentinel" 2>&1 )
  rc=$?
  if (( rc != 0 )) && sentinel_unreached && echo "$out" | grep -q "needs model 'muse-spark-1.3-contributor'"; then
    pass "wrong model fails before the sentinel"
  else
    fail "wrong model fails before the sentinel" "rc=$rc out=$out"
  fi
}

gate_setup() { # [no-cred]: stub Box serving both the real box-agent and the real helper, provider pi
  T2="$(mktemp -d "${TMPDIR:-/tmp}/box-gate-test.XXXXXX")"
  # Fixture HOME: box-agent prepends $HOME/.ascii/bin to PATH, which would
  # shadow the stub with the real Box CLI; isolate it so `box` is the stub.
  mkdir -p "$T2/stubbin" "$T2/fakebin" "$T2/boxhome/.pi/agent" "$T2/boxhome" "$T2/home"
  if [[ "${1:-}" != "no-cred" ]]; then
    printf '{"provider":"zai","fixture":"no-secret"}\n' > "$T2/boxhome/.pi/agent/auth.json"
  fi
  export GATE_T="$T2"
  cat > "$T2/fakebin/pi" <<'FAKE'
#!/usr/bin/env bash
echo "pi $*" >>"$GATE_T/calls.log"
[[ " $* " == *" -p "* ]] || { echo "pi: missing -p" >&2; exit 1; }
[[ " $* " == *" --provider zai-api "* ]] || { echo "pi: wrong provider" >&2; exit 1; }
[[ " $* " == *" --model glm-5.3-flash "* ]] || { echo "pi: wrong model" >&2; exit 1; }
[[ " $* " == *" --no-extensions "* && " $* " == *" -a "* ]] || { echo "pi: missing --no-extensions/-a" >&2; exit 1; }
prompt="${@: -1}"
[[ "$prompt" =~ ([0-9]+)\*([0-9]+) ]] || { echo "pi: no arithmetic in prompt" >&2; exit 1; }
prod=$((BASH_REMATCH[1] * BASH_REMATCH[2]))
[[ "$prompt" =~ to\ ([^[:space:]]+/result\.txt) ]] || { echo "pi: no result file in prompt" >&2; exit 1; }
printf '%s\n' "$prod" >"${BASH_REMATCH[1]}"; printf '%s\n' "$prod"
FAKE
  chmod +x "$T2/fakebin/pi"
  cat > "$T2/stubbin/box" <<'STUB'
#!/usr/bin/env bash
T="${GATE_T:?}"
map() { case "$1" in /home/user/*) printf '%s/%s' "$T/boxhome" "${1#/home/user/}" ;; *) printf '%s' "$1" ;; esac; }
jout() { python3 -c 'import json,sys; print(json.dumps({"stdout":open(sys.argv[1]).read(),"stderr":open(sys.argv[2]).read(),"exitCode":int(sys.argv[3])}))' "$1" "$2" "$3"; }
sub="${1:-}"; shift || true
case "$sub" in
  new) printf '1' >>"$T/new-count"; echo '{"id":"bx_9gate7x"}' ;;
  scp) cp "$1" "$(map "${2#*:}")"; printf '%s\n' "${2#*:}" >>"$T/scp.log" ;;
  stop) printf '%s\n' "$*" >>"$T/stop.log" ;;
  list) echo '[]' ;;
  exec)
    after=0; cmd=(); json=0
    for a in "$@"; do
      [[ "$a" == "--json" ]] && json=1
      if (( after )); then cmd+=("$a"); continue; fi
      [[ "$a" == "--" ]] && after=1
    done
    (( json )) || exit 0
    case "${cmd[0]:-}" in
      command) printf '{"stdout":"/home/user/.local/bin/pi","stderr":"","exitCode":0}\n' ;;
      test) if [[ -s "$(map "${cmd[2]}")" ]]; then printf '{"stdout":"","stderr":"","exitCode":0}\n'; else printf '{"stdout":"","stderr":"","exitCode":1}\n'; fi ;;
      mktemp) d="$(mktemp -d "$(map "${cmd[2]}")")"; o="$(mktemp)"; printf '%s\n' "$d" >"$o"; e="$(mktemp)"; : >"$e"; jout "$o" "$e" 0 ;;
      bash)
        r="$(map "${cmd[1]}")"
        if [[ "$r" == *box-agent-run.sh ]]; then printf 'runner-executed\n' >>"$T/runner.log"; printf '{"stdout":"simulated agent run","stderr":"","exitCode":0}\n';
        else env -i HOME="$T/boxhome" PATH="$T/fakebin:/usr/bin:/bin" GATE_T="$T" bash "$r" "${cmd[2]}" >"$T/probe.out" 2>"$T/probe.err"; jout "$T/probe.out" "$T/probe.err" "$?"; fi ;;
      cat) o="$(mktemp)"; e="$(mktemp)"; cat "$(map "${cmd[1]}")" >"$o" 2>"$e"; rc=$?; jout "$o" "$e" "$rc" ;;
      rm|mkdir|true|gh|git) printf '{"stdout":"","stderr":"","exitCode":0}\n' ;;
      *) echo "gate stub box exec: unknown: ${cmd[*]}" >&2; exit 99 ;;
    esac
    ;;
  *) echo "gate stub box: unknown $sub" >&2; exit 99 ;;
esac
STUB
  chmod +x "$T2/stubbin/box"
}

test_gate_success() {
  gate_setup
  out=$( HOME="$T2/home" PATH="$T2/stubbin:$PATH" GATE_T="$T2" BOX_PROBE_BASE="$T2/boxhome" "$DIR/box-agent" pi --repo testowner/testrepo "add a probe note" 2>&1 ); rc=$?
  ok=1
  (( rc == 0 )) || ok=0
  echo "$out" | grep -q "box-provider-readiness: READY box=bx_9gate7x provider=pi" || ok=0
  echo "$out" | grep -q "box-agent: NO diff" || ok=0
  grep -q "box-agent-run.sh" "$T2/scp.log" 2>/dev/null || ok=0
  grep -q "runner-executed" "$T2/runner.log" 2>/dev/null || ok=0
  [[ "$(cat "$T2/new-count" 2>/dev/null)" == "1" ]] || ok=0
  grep -q -- "--provider zai-api" "$T2/calls.log" 2>/dev/null || ok=0
  rm -rf "$T2"
  if (( ok )); then pass "dispatch gate: ready Box passes the live probe, then the runner ships once"; else fail "dispatch gate: ready Box passes the probe, then runs" "rc=$rc out=$out"; fi
}

test_gate_bootstrap_failure() {
  gate_setup no-cred
  out=$( HOME="$T2/home" PATH="$T2/stubbin:$PATH" GATE_T="$T2" BOX_PROBE_BASE="$T2/boxhome" "$DIR/box-agent" pi --repo testowner/testrepo "add a probe note" 2>&1 ); rc=$?
  ok=1
  (( rc == 3 )) || ok=0
  echo "$out" | grep -q "canonical credential.*missing or empty" || ok=0
  echo "$out" | grep -q "provider bootstrap" || ok=0
  [[ ! -e "$T2/scp.log" ]] || ok=0
  [[ ! -e "$T2/runner.log" ]] || ok=0
  [[ -s "$T2/stop.log" ]] || ok=0
  [[ "$(cat "$T2/new-count" 2>/dev/null)" == "1" ]] || ok=0
  rm -rf "$T2"
  if (( ok )); then pass "dispatch gate: bootstrap failure exits 3, runner never ships, Box stopped"; else fail "dispatch gate: bootstrap failure exits 3 with no runner" "rc=$rc out=$out"; fi
}

test_fresh_success
test_resumed_transient_success
test_missing_binary
test_missing_credential
test_invalid_auth
test_wrong_write
test_timeout
test_wrong_model
test_gate_success
test_gate_bootstrap_failure

echo
echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
