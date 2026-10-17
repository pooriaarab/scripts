#!/usr/bin/env bash
# Offline tests for domain-transfer-to-cloudflare. No network, no secrets.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/domain-transfer-to-cloudflare"
PASS=0 FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

bash -n "$SCRIPT" && pass "bash syntax" || fail "bash syntax"
"$SCRIPT" --help >/dev/null 2>&1 && pass "help exits 0" || fail "help exits 0"
"$SCRIPT" --help 2>/dev/null | grep -q "never written to" \
  && pass "help states the EPP rule" || fail "help states the EPP rule"
"$SCRIPT" example.com >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "missing env exits 2" || fail "missing env exits 2"
grep -q "LockAction=UNLOCK" "$SCRIPT" \
  && pass "unlock uses LockAction" || fail "unlock uses LockAction"
grep -q "transfer-in" "$SCRIPT" \
  && pass "uses transfer-in endpoint" || fail "uses transfer-in endpoint"
grep -q "OutgoingTransfer/Approve" "$SCRIPT" \
  && pass "approve path present" || fail "approve path present"
NAMECHEAP_API_USER=x NAMECHEAP_API_KEY=x NAMECHEAP_USERNAME=x \
  NAMECHEAP_CLIENT_IP=127.0.0.1 CLOUDFLARE_API_TOKEN=x CLOUDFLARE_ACCOUNT_ID=x \
  "$SCRIPT" 'bad&Command=pwn' >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "rejects smuggled parameter" || fail "rejects smuggled parameter"
if grep -Eq "BEGIN [A-Z ]*PRIVATE KEY|ApiKey=[0-9a-f]{32}" "$SCRIPT"; then
  fail "no key material in script"
else
  pass "no key material in script"
fi
echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
