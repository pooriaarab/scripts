#!/bin/bash
# claude-subs-resync has two failure modes that matter in CI: it must run
# without a macOS `security` binary (keychain absent → OffRouter store is the
# fallback source), and it must never write during --check/--dry-run. These
# tests pin both against fixture stores in a temp dir.
set -uo pipefail

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export OFFROUTER_HOME="$TMP/offrouter"
export CODEXBAR_CONFIG="$TMP/codexbar.json"
export CLAUDE_OAUTH_ENV="$TMP/claude-oauth.env"
export CLAUDE_SUBS_MAP="$TMP/accounts.json"
mkdir -p "$OFFROUTER_HOME/state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cat > "$CLAUDE_SUBS_MAP" <<'J'
{"accounts":[{"id":"personal","configDir":"~/.claude-personal",
              "codexbarLabel":"you@","envSuffix":"YOU_AT_EXAMPLE_COM"}]}
J
echo '{"secrets":{"anthropic:personal:oauth":"{\"accessToken\":\"x\",\"expiresAt\":1}"}}' \
  > "$OFFROUTER_HOME/secrets.json"
echo '{"accounts":{}}' > "$OFFROUTER_HOME/state/usage.json"
echo '{"providers":[{"id":"claude","tokenAccounts":{"accounts":[]}}]}' > "$CODEXBAR_CONFIG"
touch "$CLAUDE_OAUTH_ENV"

fails=0
check() { # $1 desc  $2 condition-result
  if [ "$2" -eq 0 ]; then echo "ok - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi
}

# 1. compiles
python3 -m py_compile "$SCRIPT_DIR/claude-subs-resync"
check "script compiles" $?

# 2. --check runs with no keychain and reports the missing refresh token
out=$(python3 "$SCRIPT_DIR/claude-subs-resync" --check 2>&1)
echo "$out" | grep -q 'offrouter refresh=NO'
check "--check reports missing offrouter refresh token" $?

# 3. --check writes nothing: secrets.json byte-identical after the run
sum_before=$(shasum "$OFFROUTER_HOME/secrets.json" | cut -d' ' -f1)
python3 "$SCRIPT_DIR/claude-subs-resync" --check >/dev/null 2>&1
sum_after=$(shasum "$OFFROUTER_HOME/secrets.json" | cut -d' ' -f1)
[ "$sum_before" = "$sum_after" ]
check "--check leaves secrets.json untouched" $?

# 4. --dry-run reports instead of writing; usage.json untouched
python3 "$SCRIPT_DIR/claude-subs-resync" --dry-run >/dev/null 2>&1
grep -q '"accounts":{}' "$OFFROUTER_HOME/state/usage.json" 2>/dev/null || \
  python3 -c "import json;d=json.load(open('$OFFROUTER_HOME/state/usage.json'));assert d['accounts']=={}"
check "--dry-run leaves usage.json untouched" $?

# 5. a missing map file fails loudly, not silently
rm "$CLAUDE_SUBS_MAP"
python3 "$SCRIPT_DIR/claude-subs-resync" --check >/dev/null 2>&1
[ $? -ne 0 ]
check "missing accounts.json exits non-zero" $?

echo; [ $fails -eq 0 ] && echo "all tests passed" || { echo "$fails failed"; exit 1; }
