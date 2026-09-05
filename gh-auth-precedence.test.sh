#!/usr/bin/env bash
# Synthetic gh credential-precedence tests (SCR-310: readiness under stale
# inherited credentials). Fake HOME plus synthetic-only values: no real
# secrets, no Box, no state changes. Real gh binary, read-only subcommands.
set -uo pipefail
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/gh-cred-prec.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/gh"
printf 'github.com:\n    user: synthetic-file-user\n    oauth_token: synthetic-file-token-000\n' > "$T/home/.config/gh/hosts.yml"
ghbase() { env -u GH_TOKEN -u GITHUB_TOKEN HOME="$T/home" GH_TOKEN="${STALE_GH_TOKEN:-}" gh "$@"; }
test_file_active_when_env_scrubbed() {
  out=$(STALE_GH_TOKEN="" ghbase auth status 2>&1)
  if echo "$out" | grep -q "hosts.yml" && echo "$out" | grep -q "Active account: true" \
    && ! echo "$out" | grep -qE "GH_TOKEN|GITHUB_TOKEN"; then
    pass "env scrubbed: canonical token file is the active account"
  else fail "env scrubbed: canonical token file is the active account" "$out"; fi
}
test_inherited_env_shadows_file() {
  out=$(STALE_GH_TOKEN="synthetic-stale-token-000" ghbase auth status 2>&1)
  if echo "$out" | grep -q "(GH_TOKEN)" && echo "$out" | grep -q "Active account: false"; then
    pass "stale inherited GH_TOKEN shadows the file (scrub it to use the file)"
  else fail "stale inherited GH_TOKEN shadows the file" "$out"; fi
}
test_expired_inherited_token_detected() {
  out=$(STALE_GH_TOKEN="synthetic-stale-token-000" ghbase api user 2>&1); rc=$?
  if (( rc != 0 )) && echo "$out" | grep -q "401"; then
    pass "expired inherited token fails closed with HTTP 401, never silent"
  else fail "expired inherited token fails closed with HTTP 401" "rc=$rc out=$out"; fi
}
test_file_active_when_env_scrubbed
test_inherited_env_shadows_file
test_expired_inherited_token_detected
echo
echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
