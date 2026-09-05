#!/usr/bin/env bash
# Pins the pi provider defaults written by box-setup/install-agent-clis.sh:
# valid JSON, zai-api roster intact, openrouter deepseek/deepseek-v3.2 capped.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$DIR/install-agent-clis.sh" <<'PY'
import json,re,sys
src=open(sys.argv[1]).read()
m=re.search(r'cat > "\$HOME/\.pi/agent/models\.json" <<\'JSON\'\n(.*?)\nJSON',src,re.S)
assert m, "models.json heredoc missing"
d=json.loads(m.group(1))
assert "zai-api" in d["providers"], "zai roster lost"
ov=d["providers"]["openrouter"]["modelOverrides"]["deepseek/deepseek-v3.2"]
assert ov == {"maxTokens":8192}, ov
print("ok - pi factory models cap openrouter deepseek-v3.2 at maxTokens=8192")
PY
