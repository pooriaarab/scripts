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
    body=$(cat "$fix/zones.json")
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
    "$SCRIPT" 2>&1
}

# --- 1. sending subdomain with no MX: reported, exit non-zero --------------
FIX1="$ROOT/missing-mx"
setup_fix "$FIX1"
envelope '[{"id":"z1","name":"popcornteam.org","status":"active"}]' > "$FIX1/zones.json"
envelope '[{"name":"go.popcornteam.org","enabled":true}]' > "$FIX1/sending/z1.json"
envelope '[{"enabled":true,"matchers":[{"type":"literal","field":"to","value":"hello@popcornteam.org"}],"actions":[{"type":"forward","value":["pooria@gmail.com"]}]}]' > "$FIX1/rules/z1.json"
envelope '{"enabled":true,"matchers":[{"type":"all"}],"actions":[{"type":"drop"}]}' > "$FIX1/catch_all/z1.json"
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
case "$out1" in
  *hello@popcornteam.org*forward\ -\>\ pooria@gmail.com*) ok "routing rule is reported on a faulting zone" ;;
  *) bad "routing rule missing on faulting zone: $out1" ;;
esac
case "$out1" in
  *catch-all:\ drop*) ok "drop catch-all is reported" ;;
  *) bad "drop catch-all missing: $out1" ;;
esac

# --- 2. third-party apex MX: reported, does not fail -----------------------
FIX2="$ROOT/third-party"
setup_fix "$FIX2"
envelope '[{"id":"z2","name":"beeloud.xyz","status":"active"}]' > "$FIX2/zones.json"
envelope '[]' > "$FIX2/sending/z2.json"
envelope '[]' > "$FIX2/rules/z2.json"
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
case "$out2" in
  *'routing: (none)'*) ok "empty routing is reported" ;;
  *) bad "empty routing missing: $out2" ;;
esac
case "$out2" in
  *'catch-all: none'*) ok "missing catch-all is reported as none" ;;
  *) bad "missing catch-all not reported: $out2" ;;
esac

# --- 3. fully healthy fleet: exit zero -------------------------------------
FIX3="$ROOT/healthy"
setup_fix "$FIX3"
envelope '[{"id":"z3","name":"healthy.test","status":"active"}]' > "$FIX3/zones.json"
envelope '[{"name":"mail.healthy.test","enabled":true}]' > "$FIX3/sending/z3.json"
envelope '[{"enabled":true,"matchers":[{"type":"literal","field":"to","value":"hello@healthy.test"}],"actions":[{"type":"forward","value":["inbox@healthy.test"]}]}]' > "$FIX3/rules/z3.json"
envelope '{"enabled":true,"matchers":[{"type":"all"}],"actions":[{"type":"forward","value":["catch@healthy.test"]}]}' > "$FIX3/catch_all/z3.json"
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
case "$out3" in
  *hello@healthy.test*forward\ -\>\ inbox@healthy.test*) ok "routing rule is reported" ;;
  *) bad "routing rule missing: $out3" ;;
esac
case "$out3" in
  *catch-all:\ forward\ -\>\ catch@healthy.test*) ok "catch-all is reported" ;;
  *) bad "catch-all missing: $out3" ;;
esac

# --- 4. disabled catch-all is reported ------------------------------------
FIX4="$ROOT/disabled-catch"
setup_fix "$FIX4"
envelope '[{"id":"z4","name":"quiet.test","status":"active"}]' > "$FIX4/zones.json"
envelope '[]' > "$FIX4/sending/z4.json"
envelope '[]' > "$FIX4/rules/z4.json"
envelope '{"enabled":false,"matchers":[{"type":"all"}],"actions":[{"type":"drop"}]}' > "$FIX4/catch_all/z4.json"
printf '10 route1.mx.cloudflare.net.\n' > "$FIX4/mx/quiet.test"

out4=$(run_audit "$FIX4")
st4=$?
[ $st4 -eq 0 ] && ok "disabled catch-all does not cause a non-zero exit" || bad "disabled catch-all exited $st4: $out4"
case "$out4" in
  *'catch-all: disabled (drop)'*) ok "disabled catch-all is reported" ;;
  *) bad "disabled catch-all missing: $out4" ;;
esac

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
