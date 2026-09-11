#!/usr/bin/env bash
# capture-page-map.test.sh — no browser required.
# Stubs agent-browser so the parse, the leak guards and the failure paths are
# exercised without a live page.
set -u
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# agent-browser returns the eval result as a JSON-encoded string.
payload='{"url":"https://example.test/acct","title":"Acct","count":2,"elements":[{"tag":"button","type":null,"label":"Download","selector":"#dl","disabled":false,"below_fold":true},{"tag":"select","type":null,"label":"month","selector":"#m","disabled":false,"below_fold":false,"option_count":13}]}'
cat > "$TMP/agent-browser" <<STUB
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' '$payload'
STUB
chmod +x "$TMP/agent-browser"

OUT="$TMP/map.json"
if AGENT_BROWSER="$TMP/agent-browser" PAGE_MAP_OUT="$OUT" node capture-page-map.mjs >"$TMP/log" 2>&1
then ok "runs against a stubbed browser"; else no "runs against a stubbed browser"; cat "$TMP/log"; fi

grep -q '"count": 2' "$OUT" 2>/dev/null && ok "parses the double-encoded payload" || no "parses the double-encoded payload"
grep -q '"below_fold": true' "$OUT" 2>/dev/null && ok "records below_fold" || no "records below_fold"
grep -q '"option_count": 13' "$OUT" 2>/dev/null && ok "records option_count" || no "records option_count"
# The guarantee that makes this output committable.
grep -qi 'options"' "$OUT" 2>/dev/null && no "must not capture option text" || ok "does not capture option text"
grep -q 'captured_at' "$OUT" 2>/dev/null && ok "stamps captured_at" || no "stamps captured_at"

# An empty page is a redirect or a login wall, never a page with no controls.
cat > "$TMP/agent-browser" <<'STUB'
#!/usr/bin/env bash
python3 -c 'import json; print(json.dumps(json.dumps({"url":"u","title":"t","count":0,"elements":[]})))'
STUB
chmod +x "$TMP/agent-browser"
if AGENT_BROWSER="$TMP/agent-browser" PAGE_MAP_OUT="$TMP/empty.json" node capture-page-map.mjs >/dev/null 2>&1
then no "fails loudly on zero controls"; else ok "fails loudly on zero controls"; fi

# A dead browser must not look like a clean run.
cat > "$TMP/agent-browser" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
chmod +x "$TMP/agent-browser"
if AGENT_BROWSER="$TMP/agent-browser" PAGE_MAP_OUT="$TMP/x.json" node capture-page-map.mjs >/dev/null 2>&1
then no "fails when the browser errors"; else ok "fails when the browser errors"; fi

echo "capture-page-map.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
