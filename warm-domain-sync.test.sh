#!/usr/bin/env bash
# Offline tests for warm-domain-sync. Fake src/dst trees; never touches live.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/warm-domain-sync"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
SRC="$ROOT/src"; DST="$ROOT/dst"
mkdir -p "$SRC/scripts/lib" "$DST/scripts" "$DST/config" "$DST/state"
echo "// warmctl" > "$SRC/scripts/warmctl.mjs"
echo "sentinel" > "$DST/config/keep.json"

run() { WARM_DOMAIN_SRC="$SRC" WARM_DOMAIN_HOME="$DST" "$SCRIPT" "$@"; }

# 1. Sync copies new files, keeps modes, leaves config/ alone.
echo "v1" > "$SRC/scripts/a.mjs"
echo "x" > "$SRC/scripts/lib/b.mjs"
chmod +x "$SRC/scripts/a.mjs"
OUT=$(run) || bad "sync exits 0"
[ -f "$DST/scripts/a.mjs" ] && [ -f "$DST/scripts/lib/b.mjs" ] && ok "sync copies files" || bad "sync copies files"
[ -x "$DST/scripts/a.mjs" ] && ok "sync keeps mode" || bad "sync keeps mode"
[ "$(cat "$DST/config/keep.json")" = sentinel ] && ok "config untouched" || bad "config untouched"
echo "$OUT" | grep -q "3 synced" && ok "sync count" || bad "sync count: $OUT"

# 2. Clean tree: --check exits 0.
OUT=$(run --check) && ok "check clean exits 0" || bad "check clean exits 0"
echo "$OUT" | grep -q "in sync" && ok "check clean message" || bad "check clean message: $OUT"

# 3. Modified file: --check exits 2 and names it; sync repairs.
echo "v2" > "$SRC/scripts/a.mjs"
OUT=$(run --check 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "check differs exits 2" || bad "check differs exits $RC"
echo "$OUT" | grep -q "differs: scripts/a.mjs" && ok "check names file" || bad "check names file: $OUT"
run >/dev/null && [ "$(cat "$DST/scripts/a.mjs")" = v2 ] && ok "sync repairs" || bad "sync repairs"

# 4. Live-only file is drift; sync never deletes it.
echo "rogue" > "$DST/scripts/rogue.sh"
OUT=$(run --check 2>&1); RC=$?
[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "live-only: scripts/rogue.sh" && ok "live-only flagged" || bad "live-only flagged: $RC $OUT"
run >/dev/null; [ -f "$DST/scripts/rogue.sh" ] && ok "sync never deletes" || bad "sync never deletes"

# 5. Missing toolkit and src==dst are refused.
WARM_DOMAIN_SRC="$ROOT/empty" WARM_DOMAIN_HOME="$DST" "$SCRIPT" --check >/dev/null 2>&1
[ "$?" -eq 127 ] && ok "missing toolkit exits 127" || bad "missing toolkit exit"
WARM_DOMAIN_SRC="$SRC" WARM_DOMAIN_HOME="$SRC" "$SCRIPT" --check >/dev/null 2>&1
[ "$?" -eq 64 ] && ok "src==dst refused" || bad "src==dst exit"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
