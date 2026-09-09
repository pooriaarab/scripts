#!/bin/bash
# The whole point of this helper is that a credential snapshot survives contexts
# where it cannot reach every destination. On macOS, launchd has no TCC grant for
# ~/Documents, so the scheduled run cannot write the .secrets mirror. An earlier
# revision let that PermissionError abort capture, so the hourly job wrote nothing
# and the "backup" was silently a week stale. These tests pin that behaviour:
# an unreachable mirror must degrade to a warning, never fail the capture.
set -uo pipefail

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export CLIPROXY_LIVE_DIR="$TMP/live"
export CLIPROXY_STORE_DIR="$TMP/store"
export CLIPROXY_SECRETS_DIR="$TMP/secrets"
export CLIPROXY_ENV_FILE="$TMP/secrets/fullscope.env"
export CLIPROXY_SKIP_CODEXBAR=1
mkdir -p "$CLIPROXY_LIVE_DIR" "$CLIPROXY_SECRETS_DIR"

# a credential shaped like a real one, so the env-file writer has something to parse
cat > "$CLIPROXY_LIVE_DIR/claude-seat@example.com.json" <<'J'
{"type":"claude","email":"seat@example.com","access_token":"sk-ant-oat01-AAA",
 "refresh_token":"sk-ant-ort01-BBB","expired":"2030-01-01T00:00:00-07:00",
 "account_uuid":"11111111-2222-3333-4444-555555555555"}
J
# a credential with no refresh token must be stored but kept out of the env file
cat > "$CLIPROXY_LIVE_DIR/claude-static@example.com.json" <<'J'
{"type":"claude","email":"static@example.com","access_token":"sk-ant-oat01-CCC"}
J
# config.yaml carries the api-keys and routing, so a restore must bring it back too
echo "api-keys: [DDD]" > "$CLIPROXY_LIVE_DIR/config.yaml"

fail=0
ok()   { echo "  OK   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }

out=$(./cliproxy-creds capture 2>&1)
[ -f "$CLIPROXY_STORE_DIR/claude-seat@example.com.json" ] \
  && ok "capture copies credentials into the store" \
  || bad "capture did not populate the store"

grep -q 'sk-ant-ort01-BBB' "$CLIPROXY_ENV_FILE" 2>/dev/null \
  && ok "env file carries the refresh token, the durable half" \
  || bad "env file is missing the refresh token"

grep -q 'sk-ant-oat01-CCC' "$CLIPROXY_ENV_FILE" 2>/dev/null \
  && bad "a credential with no refresh token leaked into the env file" \
  || ok "credentials without a refresh token stay out of the env file"

[ -f "$CLIPROXY_STORE_DIR/config.yaml" ] \
  && ok "capture stores config.yaml alongside the credentials" \
  || bad "capture did not store config.yaml"

# THE REGRESSION THIS FILE EXISTS FOR: an unreachable mirror must not fail capture.
# Model the real case faithfully. Under TCC the whole ~/Documents subtree is
# unreadable to launchd, so the mirror directory cannot even be created. Making
# only the parent read-only is not the same thing: an already-created mirror dir
# stays writable and the copy succeeds, which is why an earlier draft of this
# test passed against a script that would still have broken on a real Mac.
BLOCKED="$TMP/blocked"
mkdir -p "$BLOCKED"; chmod 500 "$BLOCKED"
out=$(CLIPROXY_SECRETS_DIR="$BLOCKED/secrets" \
      CLIPROXY_ENV_FILE="$BLOCKED/secrets/fullscope.env" \
      ./cliproxy-creds capture 2>&1); rc=$?
chmod 700 "$BLOCKED"
[ $rc -eq 0 ] \
  && ok "capture still exits 0 when the mirror is unreachable" \
  || bad "capture exited $rc when the mirror was unreachable"
printf '%s' "$out" | grep -q 'skipped' \
  && ok "capture reports the skip instead of claiming success" \
  || bad "capture hid the unreachable mirror"

# restore must rebuild a wiped live dir from the store, with no login
rm -rf "$CLIPROXY_LIVE_DIR"; mkdir -p "$CLIPROXY_LIVE_DIR"
./cliproxy-creds restore >/dev/null 2>&1
[ -f "$CLIPROXY_LIVE_DIR/claude-seat@example.com.json" ] \
  && ok "restore rebuilds the live directory from the store" \
  || bad "restore did not rebuild the live directory"

grep -q 'sk-ant-ort01-BBB' "$CLIPROXY_LIVE_DIR/claude-seat@example.com.json" \
  && ok "restored credential keeps its refresh token" \
  || bad "restored credential lost its refresh token"

[ -f "$CLIPROXY_LIVE_DIR/config.yaml" ] \
  && ok "restore brings config.yaml back to the live directory" \
  || bad "restore left config.yaml out of the live directory"

./cliproxy-creds status 2>&1 | grep -q 'seat@example.com' \
  && ok "status lists what is held" || bad "status did not list the credential"

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
