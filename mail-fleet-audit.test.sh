#!/usr/bin/env bash
# Offline tests for mail-fleet-audit. Stubs curl and dig; never sends.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/mail-fleet-audit"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# curl never talks to the network. It serves JSON from MAIL_FLEET_FIXTURE
# and appends the HTTP status so the script's -w parser keeps working.
cat > "$ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
url=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
done
[ -n "$url" ] || { echo "stub curl: no url" >&2; exit 9; }
case "$url" in
  *api.cloudflare.com*|*1.1.1.1*)
    echo "stub curl: refused real network: $url" >&2
    exit 9
    ;;
esac
fix="${MAIL_FLEET_FIXTURE:?}"
# Simulates a transport failure (a timeout) for one zone, which is different
# from a 404: curl exits non-zero and writes no status at all.
if [ -n "${MAIL_FLEET_FAIL_ZONE:-}" ] && case "$url" in *"/zones/$MAIL_FLEET_FAIL_ZONE/"*) true ;; *) false ;; esac; then
  echo "curl: (28) Connection timed out" >&2
  exit 28
fi
# path after the host, query stripped
rest="${url#*://}"
path="/${rest#*/}"
path="${path%%\?*}"
path="${path#/client/v4}"
case "$path" in /*) ;; *) path="/$path" ;; esac
body=""
status=200
case "$path" in
  /zones)
    if [ -n "${MAIL_FLEET_ZONES_STATUS:-}" ]; then
      status="$MAIL_FLEET_ZONES_STATUS"
      body='{"success":false,"errors":[{"message":"not found"}],"result":null}'
    else
      body=$(cat "$fix/zones.json")
    fi
    ;;
  /zones/*/email/sending/subdomains)
    zid="${path#/zones/}"; zid="${zid%%/*}"
    f="$fix/sending/$zid.json"
    if [ -f "$f" ]; then body=$(cat "$f"); else status=404; body='{"success":false,"errors":[{"message":"not found"}],"result":null}'; fi
    ;;
  /zones/*/email/routing/rules/catch_all)
    zid="${path#/zones/}"; zid="${zid%%/*}"
    f="$fix/catch_all/$zid.json"
    if [ -f "$f" ]; then body=$(cat "$f"); else status=404; body='{"success":false,"errors":[{"message":"not found"}],"result":null}'; fi
    ;;
  /zones/*/email/routing/rules)
    zid="${path#/zones/}"; zid="${zid%%/*}"
    f="$fix/rules/$zid.json"
    if [ -f "$f" ]; then body=$(cat "$f"); else status=404; body='{"success":false,"errors":[{"message":"not found"}],"result":null}'; fi
    ;;
  *)
    echo "stub curl: unknown path $path" >&2
    exit 9
    ;;
esac
printf '%s\n%s' "$body" "$status"
STUB
chmod +x "$ROOT/bin/curl"

# dig never talks to a resolver. MAIL_FLEET_MX/<host> is the +short MX text.
cat > "$ROOT/bin/dig" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
host=""
for a in "$@"; do
  case "$a" in
    +*|@*) ;;
    MX|mx) ;;
    *) host="$a" ;;
  esac
done
[ -n "$host" ] || { echo "stub dig: no host" >&2; exit 9; }
f="${MAIL_FLEET_MX:?}/$host"
if [ -f "$f" ]; then cat "$f"; exit 0; fi
# Missing file = no MX, which is the condition the audit exists to see.
exit 0
STUB
chmod +x "$ROOT/bin/dig"

envelope() {
  python3 -c 'import json,sys; print(json.dumps({"success":True,"errors":[],"messages":[],"result":json.loads(sys.argv[1]),"result_info":{"page":1,"per_page":50,"total_pages":1,"count":len(json.loads(sys.argv[1])) if isinstance(json.loads(sys.argv[1]), list) else 1}}))' "$1"
}

setup_fix() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/sending" "$dir/rules" "$dir/catch_all" "$dir/mx"
}

run_audit() {
  local fix="$1"
  MAIL_FLEET_FIXTURE="$fix" MAIL_FLEET_MX="$fix/mx" \
    PATH="$ROOT/bin:$PATH" \
    CLOUDFLARE_API_TOKEN="test-token" \
    CLOUDFLARE_API_BASE="http://mail-fleet-audit.test/client/v4" \
    MAIL_FLEET_CURL="$ROOT/bin/curl" \
    MAIL_FLEET_DIG="$ROOT/bin/dig" \
    MAIL_FLEET_RESOLVER="1.1.1.1" \
    MAIL_FLEET_ZONES_STATUS="${MAIL_FLEET_ZONES_STATUS:-}" \
    "$SCRIPT" 2>&1
}

# --- 1. sending subdomain with no MX: reported, exit non-zero --------------
FIX1="$ROOT/missing-mx"
setup_fix "$FIX1"
envelope '[{"id":"z1","name":"popcornteam.org","status":"active"}]' > "$FIX1/zones.json"
envelope '[{"name":"go.popcornteam.org","enabled":true}]' > "$FIX1/sending/z1.json"
printf '10 route1.mx.cloudflare.net.\n20 route2.mx.cloudflare.net.\n' > "$FIX1/mx/popcornteam.org"
# go.popcornteam.org has no mx file → no MX

out1=$(run_audit "$FIX1")
st1=$?
[ $st1 -eq 1 ] && ok "sending subdomain without MX exits non-zero" || bad "missing-MX case exited $st1"
case "$out1" in
  *go.popcornteam.org*no\ MX*cannot\ receive*) ok "missing MX is reported on the sending host" ;;
  *) bad "missing MX not reported: $out1" ;;
esac
case "$out1" in
  *FAULTS*) ok "missing MX is listed under FAULTS" ;;
  *) bad "FAULTS section missing: $out1" ;;
esac

# --- 2. third-party apex MX: reported, does not fail -----------------------
FIX2="$ROOT/third-party"
setup_fix "$FIX2"
envelope '[{"id":"z2","name":"beeloud.xyz","status":"active"}]' > "$FIX2/zones.json"
envelope '[]' > "$FIX2/sending/z2.json"
printf '10 mx.zoho.com.\n20 mx2.zoho.com.\n' > "$FIX2/mx/beeloud.xyz"

out2=$(run_audit "$FIX2")
st2=$?
[ $st2 -eq 0 ] && ok "third-party apex MX does not cause a non-zero exit" || bad "third-party case exited $st2: $out2"
case "$out2" in
  *beeloud.xyz*third\ party:\ Zoho*) ok "third-party apex MX is reported as Zoho" ;;
  *) bad "third-party MX not reported plainly: $out2" ;;
esac
case "$out2" in
  *FAULTS*) bad "third-party MX was flagged as a fault: $out2" ;;
  *) ok "third-party MX is not a fault" ;;
esac

# --- 3. fully healthy fleet: exit zero -------------------------------------
FIX3="$ROOT/healthy"
setup_fix "$FIX3"
envelope '[{"id":"z3","name":"healthy.test","status":"active"}]' > "$FIX3/zones.json"
envelope '[{"name":"mail.healthy.test","enabled":true}]' > "$FIX3/sending/z3.json"
printf '10 route1.mx.cloudflare.net.\n' > "$FIX3/mx/healthy.test"
printf '10 route1.mx.cloudflare.net.\n' > "$FIX3/mx/mail.healthy.test"

out3=$(run_audit "$FIX3")
st3=$?
[ $st3 -eq 0 ] && ok "healthy fleet exits zero" || bad "healthy fleet exited $st3: $out3"
case "$out3" in
  *mail.healthy.test*route1.mx.cloudflare.net*) ok "healthy sending subdomain MX is reported" ;;
  *) bad "healthy sending MX missing from report: $out3" ;;
esac
case "$out3" in
  *FAULTS*) bad "healthy fleet listed FAULTS: $out3" ;;
  *ok:\ every\ sending\ host\ can\ receive*) ok "healthy fleet prints the ok line" ;;
  *) bad "healthy fleet missing ok line: $out3" ;;
esac

# --- 4. a zone that cannot be read is a fault, never a clean pass ----------
# An audit that could not look must not report "nothing wrong". Omitting the
# sending fixture makes the stub fail that one request, which is what a real
# timeout looks like to the script.
FIX4="$ROOT/unreadable"
setup_fix "$FIX4"
envelope '[{"id":"z4","name":"opaque.test","status":"active"},{"id":"z5","name":"fine.test","status":"active"}]' > "$FIX4/zones.json"
# MAIL_FLEET_FAIL_ZONE makes every z4 request time out at the transport
# layer, which is what a real slow zone looks like to the script.
envelope '[]' > "$FIX4/sending/z4.json"
envelope '[]' > "$FIX4/sending/z5.json"
printf '10 route1.mx.cloudflare.net.\n' > "$FIX4/mx/opaque.test"
printf '10 route1.mx.cloudflare.net.\n' > "$FIX4/mx/fine.test"

out4=$(MAIL_FLEET_FAIL_ZONE=z4 run_audit "$FIX4")
st4=$?
[ $st4 -ne 0 ] && ok "unreadable zone exits non-zero" || bad "unreadable zone exited 0: $out4"
case "$out4" in
  *COULD\ NOT\ AUDIT*) ok "unreadable zone is named in the report" ;;
  *) bad "unreadable zone not reported: $out4" ;;
esac
case "$out4" in
  *fine.test*) ok "a later zone is still audited after an unreadable one" ;;
  *) bad "audit stopped at the unreadable zone: $out4" ;;
esac

# --- 5. GET /zones itself failing must never look like a clean audit ------
# A broken CLOUDFLARE_API_BASE or a token missing Zone Read makes the
# top-level zones call fail. Unlike a per-zone subresource, "empty" here
# is indistinguishable from "the audit never ran" and must not print ok.
FIX5="$ROOT/zones-unreadable"
setup_fix "$FIX5"

out5=$(MAIL_FLEET_ZONES_STATUS=404 run_audit "$FIX5")
st5=$?
[ $st5 -eq 2 ] && ok "a failed /zones call exits with the API-error code" || bad "failed /zones call exited $st5: $out5"
case "$out5" in
  *ok:\ every\ sending\ host\ can\ receive*) bad "failed /zones call was reported as a clean audit: $out5" ;;
  *) ok "failed /zones call is not reported as clean" ;;
esac

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
