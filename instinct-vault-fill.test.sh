#!/bin/bash
# instinct-vault-fill never touches a live vault in CI. These tests pin the
# parts that don't need one: it compiles, --help works, a missing entries
# file fails loudly, and the idempotent skip path takes effect when a
# snapshot already lists an entry's name — using a stub `agent-browser` on
# PATH instead of a real browser session.
set -uo pipefail

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

fails=0
check() { # $1 desc  $2 condition-result
  if [ "$2" -eq 0 ]; then echo "ok - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi
}

# 1. compiles
python3 -m py_compile "$SCRIPT_DIR/instinct-vault-fill"
check "script compiles" $?

# 2. --help prints usage without touching a browser
out=$(python3 "$SCRIPT_DIR/instinct-vault-fill" --help 2>&1)
echo "$out" | grep -q 'entries'
check "--help documents the entries argument" $?

# 3. a missing entries file fails loudly, not silently
python3 "$SCRIPT_DIR/instinct-vault-fill" "$TMP/does-not-exist.json" >/dev/null 2>&1
[ $? -ne 0 ]
check "missing entries.json exits non-zero" $?

# 4. idempotent skip: a stub agent-browser reports the entry already in the
#    vault snapshot, so the fill loop must skip it rather than open a dialog.
cat > "$TMP/agent-browser" <<'S'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    snapshot) echo 'list "Vault" > text "ExistingSite"'; exit 0 ;;
  esac
done
exit 0
S
chmod +x "$TMP/agent-browser"

cat > "$TMP/entries.json" <<'J'
[{"name": "ExistingSite", "username": "u", "password": "p"}]
J

out=$(PATH="$TMP:$PATH" python3 "$SCRIPT_DIR/instinct-vault-fill" "$TMP/entries.json" 2>&1)
echo "$out" | grep -q 'DONE ok=0 fail=0 skip=1'
check "entry already in vault snapshot is skipped, not refilled" $?

echo; [ $fails -eq 0 ] && echo "all tests passed" || { echo "$fails failed"; exit 1; }
