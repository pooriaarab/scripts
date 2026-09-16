#!/usr/bin/env bash
# Offline tests for find-leads. Stubs curl; never sends.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/find-leads"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# curl never talks to the network. It serves fixture JSON by endpoint id
# and appends the HTTP status so the script's -w parser keeps working.
cat > "$ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ -n "${FIND_LEADS_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$FIND_LEADS_ARGV_LOG"
url=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
done
[ -n "$url" ] || { echo "stub curl: no url" >&2; exit 9; }
case "$url" in
  *api.treg.to*|*treg.to*)
    echo "stub curl: refused real network: $url" >&2
    exit 9
    ;;
esac
fix="${FIND_LEADS_FIXTURE:?}"
body=""
case "$url" in
  *treg.google.serp.maps*) body=$(cat "$fix/maps.json") ;;
  *hunter.companies.emails*|*treg.people.search*) body=$(cat "$fix/emails.json") ;;
  *treg.people.enrich*|*treg.people.phone.find*)
    if [ -f "$fix/enrich.json" ]; then body=$(cat "$fix/enrich.json"); else body='{}'; fi ;;
  *) echo "stub curl: unknown endpoint $url" >&2; exit 9 ;;
esac
printf '%s\n%s' "$body" "200"
STUB
chmod +x "$ROOT/bin/curl"

run_leads() {
  local fix="$1"; shift
  local dir="$1"; shift
  FIND_LEADS_FIXTURE="$fix" \
    PATH="$ROOT/bin:$PATH" \
    TREG_TOKEN="test-token" TREG_ORG="test-org" \
    TREG_BASE="http://find-leads.test" \
    FIND_LEADS_CURL="$ROOT/bin/curl" \
    "$SCRIPT" "$@" --out "$dir/leads.csv" --rejects "$dir/rejects.csv" 2>&1
}

# --- 1. first-name-only match is rejected, reason recorded -----------------
FIX1="$ROOT/first-name-only"
mkdir -p "$FIX1" "$ROOT/t1"
cat > "$FIX1/maps.json" <<'JSON'
{"places": [{"title": "Acme Studio", "phone": "+1 604-555-0100", "address": "1 Main St", "website": "https://acme.example.com"}]}
JSON
cat > "$FIX1/emails.json" <<'JSON'
{"emails": [{"first_name": "Dana", "last_name": "Condemi", "email": "dana@acme.example.com", "role": "Manager", "phone": "+1 604-555-0100"}]}
JSON
echo '{}' > "$FIX1/enrich.json"

out1=$(run_leads "$FIX1" "$ROOT/t1" --query "studios" --location "Vancouver")
st1=$?
[ $st1 -eq 0 ] && ok "first-name-only case exits cleanly" || bad "first-name-only case exited $st1: $out1"
[ ! -f "$ROOT/t1/leads.csv" ] && ok "fabricated surname keeps the row out of the CSV" || bad "fabricated surname reached the CSV"
if [ -f "$ROOT/t1/rejects.csv" ] && grep -q "surname-not-in-email" "$ROOT/t1/rejects.csv"; then
  ok "reject carries the surname reason"
else
  bad "reject reason missing: $(cat "$ROOT/t1/rejects.csv" 2>/dev/null || echo NO-REJECT-FILE)"
fi
case "$(cat "$ROOT/t1/rejects.csv" 2>/dev/null || echo MISSING)" in
  *dana@acme.example.com*) ok "reject names the dropped address" ;;
  *) bad "reject does not name the dropped address" ;;
esac

# --- 2. area code inconsistent with the location is flagged ----------------
FIX2="$ROOT/region-flag"
mkdir -p "$FIX2" "$ROOT/t2"
cat > "$FIX2/maps.json" <<'JSON'
{"places": [{"title": "Harbour Shop", "phone": "+1 604-555-0101", "address": "2 Water St", "website": "https://harbour.example.com"}]}
JSON
cat > "$FIX2/emails.json" <<'JSON'
{"emails": [{"first_name": "Bob", "last_name": "Ng", "email": "bob.ng@harbour.example.com", "role": "Owner", "phone": "+1 415-555-0101"}]}
JSON
echo '{}' > "$FIX2/enrich.json"

out2=$(run_leads "$FIX2" "$ROOT/t2" --query "shops" --location "Vancouver")
st2=$?
[ $st2 -eq 0 ] && ok "region-flag case exits cleanly" || bad "region-flag case exited $st2: $out2"
if [ -f "$ROOT/t2/leads.csv" ] && grep -q "region-flag" "$ROOT/t2/leads.csv"; then
  ok "foreign area code is flagged on the kept row"
else
  bad "foreign area code silently kept: $(cat "$ROOT/t2/leads.csv" 2>/dev/null || echo NO-CSV)"
fi

# --- 3. a source name is never overwritten by enrichment -------------------
FIX3="$ROOT/source-name-wins"
mkdir -p "$FIX3" "$ROOT/t3"
cat > "$FIX3/maps.json" <<'JSON'
{"places": [{"title": "Cedar Works", "phone": "+1 604-555-0102", "address": "3 Cedar Ave", "website": "https://cedar.example.com"}]}
JSON
cat > "$FIX3/emails.json" <<'JSON'
{"emails": [{"first_name": "Maya", "last_name": "Patel", "email": "maya.patel@cedar.example.com", "role": "Owner", "phone": ""}]}
JSON
cat > "$FIX3/enrich.json" <<'JSON'
{"name": "Zoe Quinn", "first_name": "Zoe", "last_name": "Quinn", "role": "Clerk", "phone": "+1 604-555-0199"}
JSON

out3=$(run_leads "$FIX3" "$ROOT/t3" --query "works" --location "Vancouver")
st3=$?
[ $st3 -eq 0 ] && ok "enrichment case exits cleanly" || bad "enrichment case exited $st3: $out3"
row3="$(cat "$ROOT/t3/leads.csv" 2>/dev/null || echo MISSING)"
case "$row3" in
  *"Maya Patel"*) ok "source name wins over enrichment" ;;
  *) bad "source name lost: $row3" ;;
esac
case "$row3" in
  *Zoe*) bad "enrichment identity leaked into the CSV: $row3" ;;
  *) ok "enrichment identity never reaches the CSV" ;;
esac
case "$row3" in
  *604-555-0199*) ok "enrichment still contributes the phone" ;;
  *) bad "enrichment phone missing: $row3" ;;
esac

# --- 4. no results exits cleanly, no empty CSV ------------------------------
FIX4="$ROOT/no-results"
mkdir -p "$FIX4" "$ROOT/t4"
echo '{"places": []}' > "$FIX4/maps.json"
echo '{"emails": []}' > "$FIX4/emails.json"

out4=$(run_leads "$FIX4" "$ROOT/t4" --query "nothing matching this" --location "Vancouver")
st4=$?
[ $st4 -eq 0 ] && ok "empty query exits zero" || bad "empty query exited $st4: $out4"
[ ! -f "$ROOT/t4/leads.csv" ] && ok "no empty CSV that reads as success" || bad "empty CSV emitted"
case "$out4" in
  *"no results"*) ok "empty query says so plainly" ;;
  *) bad "empty query not reported: $out4" ;;
esac

# --- the secrets must never reach the command line --------------------------
ARGVLOG="$ROOT/argv.log"
: > "$ARGVLOG"
FIND_LEADS_ARGV_LOG="$ARGVLOG" run_leads "$FIX2" "$ROOT/t2" --query "shops" --location "Vancouver" >/dev/null 2>&1
if grep -q "test-token" "$ARGVLOG"; then
  bad "the treg token appeared in curl's argv"
else
  ok "the treg token never reaches curl's argv"
fi
case "$(cat "$ARGVLOG")" in
  *"-H @-"*) ok "the auth headers travel on stdin" ;;
  *) bad "curl was not asked to read headers from stdin: $(head -1 "$ARGVLOG")" ;;
esac

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
