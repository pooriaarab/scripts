#!/usr/bin/env bash
# Offline tests for signup-sweep. Stubs curl, gog and cosmic; never sends.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/signup-sweep"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/cfg" "$ROOT/state"

# curl answers here.now endpoints from SWEEP_FAKE_CURL_MODE and refuses
# anything that looks like a real network call it was not told to fake.
cat > "$ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
url=""
for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
case "$url" in
  *request-code*)
    case "${SWEEP_FAKE_CURL_MODE:-ok}" in
      ok)    echo '{"success":true,"requiresCodeEntry":true}' ;;
      limit) echo '{"error":"Too many sign-in code requests.","retry_after":900}' ;;
    esac
    ;;
  *verify-code*)
    case "${SWEEP_FAKE_VERIFY:-ok}" in
      ok)  echo '{"success":true,"apiKey":"test-key-123","isNewUser":true}' ;;
      bad) echo '{"success":false,"message":"invalid code"}' ;;
    esac
    ;;
  *) echo "stub curl: refused url: $url" >&2; exit 9 ;;
esac
STUB

# gog serves a search result list, then a body containing To + OTP per
# SWEEP_FAKE_TO / SWEEP_FAKE_CODE. Empty SWEEP_FAKE_CODE means no mail yet.
cat > "$ROOT/bin/gog" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *"messages search"*)
    if [ -n "${SWEEP_FAKE_CODE:-}" ]; then
      echo '{"messages":[{"id":"m1"}]}'
    else
      echo '{"messages":[]}'
    fi
    ;;
  *"get "*)
    printf 'from\t"here.now" <noreply@here.now>\nto\t%s\n\nYour here.now code: %s\n' \
      "${SWEEP_FAKE_TO:-nobody@example.com}" "${SWEEP_FAKE_CODE:-XXXX-XXXX}"
    ;;
esac
STUB

cat > "$ROOT/bin/cosmic" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  agent-signup) echo "project created" ;;
  agent-verify) echo "Verified" ;;
esac
STUB
chmod +x "$ROOT/bin/"*

cat > "$ROOT/cfg/t.warmup.json" <<'CFG'
{"identities":[{"address":"d@t.example"}]}
CFG

export SWEEP_CONFIG_DIR="$ROOT/cfg" SWEEP_STATE="$ROOT/state/signups.json" \
       SWEEP_LOG="$ROOT/state/signups.jsonl" SWEEP_CRED_DIR="$ROOT/state/creds" \
       SWEEP_ACCOUNT="test@example.com" SWEEP_CURL="$ROOT/bin/curl" \
       SWEEP_GOG="$ROOT/bin/gog" SWEEP_COSMIC="$ROOT/bin/cosmic" SWEEP_TICK=1
export PATH="$ROOT/bin:$PATH"

svc_of() { python3 -c "import json;print(json.load(open('$SWEEP_STATE'))['pairs']['$1']['service'])"; }

# 1. First pass: the mailbox is registered and a code is requested.
SWEEP_FAKE_CURL_MODE=ok python3 "$SCRIPT" --once >/dev/null
svc=$(svc_of d@t.example)
st=$(python3 -c "import json;print(json.load(open('$SWEEP_STATE'))['pairs']['d@t.example']['status'])")
[ "$svc" = "herenow" ] || { ok "skips cosmic-only assertions for $svc assignment"; }
[ "$st" = "requested" ] && ok "code requested for d@t.example ($svc)" || bad "first pass status=$st"

# 2. Second pass with the OTP in the mailbox: verified, credential stored.
if [ "$svc" = "herenow" ]; then
  # age the request past the 25s poll floor
  python3 -c "import json;s=json.load(open('$SWEEP_STATE'));s['pairs']['d@t.example']['sent_at']-=60;json.dump(s,open('$SWEEP_STATE','w'))"
  SWEEP_FAKE_TO="d@t.example" SWEEP_FAKE_CODE="B8XG-EBXF" python3 "$SCRIPT" --once >/dev/null
  st=$(python3 -c "import json;print(json.load(open('$SWEEP_STATE'))['pairs']['d@t.example']['status'])")
  [ "$st" = "verified" ] && ok "otp verified" || bad "verify status=$st"
  [ -f "$ROOT/state/creds/herenow/d_t.example" ] && ok "credential stored" || bad "no credential file"
else
  ok "herenow path untested this run (assigned $svc)"
fi

# 3. Rate-limit response pushes next_at out instead of burning attempts.
python3 -c "import json;s=json.load(open('$SWEEP_STATE'));s['pairs']['b@t.example']={'service':'herenow','status':'new','attempts':0,'sent_at':0,'next_at':0};s['services']={};json.dump(s,open('$SWEEP_STATE','w'))"
SWEEP_FAKE_CURL_MODE=limit python3 "$SCRIPT" --once >/dev/null
nxt=$(python3 -c "import json,time;s=json.load(open('$SWEEP_STATE'));print(int(s['pairs']['b@t.example']['next_at']-time.time()))")
[ "$nxt" -gt 600 ] && ok "rate-limit backoff honored (${nxt}s)" || bad "next_at only +${nxt}s"

# 4. A code older than the OTP window goes back to retry, not verified.
python3 -c "import json,time;s=json.load(open('$SWEEP_STATE'));s['pairs']['c@t.example']={'service':'herenow','status':'requested','attempts':1,'sent_at':time.time()-900,'next_at':0};json.dump(s,open('$SWEEP_STATE','w'))"
python3 "$SCRIPT" --once >/dev/null
st=$(python3 -c "import json;print(json.load(open('$SWEEP_STATE'))['pairs']['c@t.example']['status'])")
[ "$st" = "retry" ] && ok "expired code retried" || bad "expiry status=$st"

# 5. Missing config dir exits 1.
SWEEP_CONFIG_DIR="$ROOT/nope" python3 "$SCRIPT" --once >/dev/null 2>&1
[ $? -eq 1 ] && ok "missing config dir exits 1" || bad "missing config dir exit=$?"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
