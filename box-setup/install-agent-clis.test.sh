#!/usr/bin/env bash
# Behavioral upgrade test: runs the real installer against fixture HOME
# configs. Existing valid configs gain only the DeepSeek cap; malformed ones
# fail clearly and untouched.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/pi-upgrade-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H/.pi/agent" "$H/.local/bin" "$H/.kimi-code/bin" "$T/fakebin"
for b in gemini pi codex claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"; done
for b in muse cursor-agent devin; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/.local/bin/$b"; chmod +x "$H/.local/bin/$b"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/.kimi-code/bin/kimi"; chmod +x "$H/.kimi-code/bin/kimi"
export PATH="$T/fakebin:$PATH"
cat > "$H/.pi/agent/models.json" <<'JSON'
{"providers": {"zai-api": {"models": [{"id": "glm-5.3-flash"}]}, "openrouter": {"models": [{"id": "keep-me"}], "modelOverrides": {"other/m": {"maxTokens": 1}}}}}
JSON
chmod 600 "$H/.pi/agent/models.json"
HOME="$H" bash "$DIR/install-agent-clis.sh" >"$T/out" 2>&1; rc=$?
[ "$rc" = "0" ] && pass "upgrade run succeeds" || fail "upgrade run succeeds" "$(tail -3 "$T/out")"
python3 - "$H/.pi/agent/models.json" <<'PY' && pass "existing config gains only the cap" || fail "existing config gains only the cap" "traceback above"
import json,sys
d=json.load(open(sys.argv[1])); p=d["providers"]; o=p["openrouter"]
assert o["modelOverrides"]["deepseek/deepseek-v3.2"]=={"maxTokens":8192}, "cap missing"
assert p["zai-api"]["models"][0]["id"]=="glm-5.3-flash", "zai lost"
assert o["models"]==[{"id":"keep-me"}], "models lost"
assert o["modelOverrides"]["other/m"]=={"maxTokens":1}, "sibling lost"
PY
[ "$(stat -c %a "$H/.pi/agent/models.json")" = "600" ] && pass "mode preserved" || fail "mode preserved" "mode changed"
HOME="$H" bash "$DIR/install-agent-clis.sh" >"$T/out2" 2>&1; rc=$?
[ "$rc" = "0" ] && pass "rerun is a clean no-op" || fail "rerun is a clean no-op" "$(tail -3 "$T/out2")"
if grep -q 'pi-models-upgrade.*FAILED' "$H/.agents/install-status.txt"; then fail "no upgrade failure marked" "$(cat "$H/.agents/install-status.txt")"; else pass "no upgrade failure marked"; fi
printf '{oops' > "$H/.pi/agent/models.json"; sha="$(cksum < "$H/.pi/agent/models.json")"
HOME="$H" bash "$DIR/install-agent-clis.sh" >"$T/out3" 2>&1; rc=$?
[ "$rc" != "0" ] && pass "malformed run exits nonzero" || fail "malformed run exits nonzero" "rc=0 unexpectedly"
if grep -q 'pi-models-upgrade.*FAILED' "$H/.agents/install-status.txt"; then pass "malformed config fails clearly"; else fail "malformed config fails clearly" "$(cat "$H/.agents/install-status.txt")"; fi
[ "$(cksum < "$H/.pi/agent/models.json")" = "$sha" ] && pass "malformed config left untouched" || fail "malformed config left untouched" "file changed"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ]
