#!/usr/bin/env bash
# Offline tests for agent-defect-rate. Stub gh on PATH.
set -uo pipefail

fail=0
pass=0

ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/agent-defect-rate"

# Setup fake gh.
FAKE_ROOT=$(mktemp -d)
FAKE_BIN="$FAKE_ROOT/bin"
FAKE_DATA="$FAKE_ROOT/data"
mkdir -p "$FAKE_BIN" "$FAKE_DATA"
trap 'rm -rf "$FAKE_ROOT"' EXIT

cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -e
DATA_DIR="${FAKE_DATA_DIR:-/tmp}"
args="$*"
if [[ "$args" == *"pulls?state=closed"* ]]; then
  cat "$DATA_DIR/prs.json" 2>/dev/null || echo "[]"
  exit 0
fi
if [[ "$args" == *"/files"* ]]; then
  # Extract PR number from .../pulls/N/files
  num=$(echo "$args" | grep -oE 'pulls/[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [[ -n "$num" && -f "$DATA_DIR/files_${num}.json" ]]; then
    cat "$DATA_DIR/files_${num}.json"
  else
    echo "[]"
  fi
  exit 0
fi
if [[ "$args" == *"commits?sha="* ]]; then
  cat "$DATA_DIR/commits.json" 2>/dev/null || echo "[]"
  exit 0
fi
if [[ "$args" == *".default_branch"* ]]; then
  cat "$DATA_DIR/default_branch" 2>/dev/null || echo "main"
  exit 0
fi
if [[ "$args" == *"repos/"* ]]; then
  # Fallback for repos/owner/repo default branch JSON
  echo '{"default_branch":"main"}'
  exit 0
fi
echo "unknown gh call: $args" >&2
exit 1
GH
chmod +x "$FAKE_BIN/gh"

export PATH="$FAKE_BIN:$PATH"
export FAKE_DATA_DIR="$FAKE_DATA"

write_prs() { cat > "$FAKE_DATA/prs.json"; }
write_commits() { cat > "$FAKE_DATA/commits.json"; }
write_files() { local n="$1"; cat > "$FAKE_DATA/files_${n}.json"; }
set_branch() { echo -n "$1" > "$FAKE_DATA/default_branch"; }

# Helper to run script and capture output.
run() {
  "$SCRIPT" "$@" 2>&1
}

# Test 1: PR with no trailer lands under unattributed.
set_branch "main"
write_prs <<'JSON'
[
  {"number":1,"title":"Add thing","body":"Closes #1\n\nAssisted-by: claude-personal:claude-opus-5","mergedAt":"2025-01-10T12:00:00Z","baseRefName":"main"},
  {"number":2,"title":"Fix typo","body":"Closes #2","mergedAt":"2025-01-11T12:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[]
JSON
write_files 1 <<'JSON'
["a.txt"]
JSON
write_files 2 <<'JSON'
["b.txt"]
JSON

out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -q "unattributed"; then
  ok "PR with no trailer lands under unattributed"
else
  fail_msg "PR with no trailer lands under unattributed — output: $out"
fi
if echo "$out" | grep -q "claude-personal:claude-opus-5"; then
  ok "PR with trailer is grouped under its agent"
else
  fail_msg "PR with trailer is grouped under its agent — output: $out"
fi

# Test 2: revert inside window counts.
write_prs <<'JSON'
[
  {"number":10,"title":"Add feature","body":"Closes #10\n\nAssisted-by: gpt-5:codex","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[{"message":"Revert \"Add feature\"","date":"2025-01-12T10:00:00Z"}]
JSON
write_files 10 <<'JSON'
["src/a.txt"]
JSON

out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -q "gpt-5:codex" && echo "$out" | grep -E -q "1[[:space:]]+1[[:space:]]+100\.0%"; then
  ok "revert inside window counts"
else
  fail_msg "revert inside window counts — output: $out"
fi

# Also check json rate
out_json=$(run owner/repo --since 2025-01-01 --window-days 7 --json)
if echo "$out_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(a["agent"]=="gpt-5:codex" and a["defects"]==1 and a["rate"]==100.0 for a in d["agents"]), "rate wrong"'; then
  ok "json output for revert inside window is correct"
else
  fail_msg "json output for revert inside window is correct — got: $out_json"
fi

# Test 3: same revert outside window does not count.
write_prs <<'JSON'
[
  {"number":10,"title":"Add feature","body":"Closes #10\n\nAssisted-by: gpt-5:codex","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[{"message":"Revert \"Add feature\"","date":"2025-01-20T10:00:00Z"}]
JSON
write_files 10 <<'JSON'
["src/a.txt"]
JSON

out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -E -q "gpt-5:codex.*0[[:space:]]+0\.0%"; then
  ok "revert outside window does not count"
else
  fail_msg "revert outside window does not count — output: $out"
fi

# Test 3b: Reverts #<pr> case-insensitive also counts inside window.
write_prs <<'JSON'
[
  {"number":11,"title":"Add thing 11","body":"Closes #11\n\nAssisted-by: pi:glm-5","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[{"message":"fix: something\n\nReverts #11","date":"2025-01-11T10:00:00Z"}]
JSON
write_files 11 <<'JSON'
["src/b.txt"]
JSON
out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -E -q "pi:glm-5.*1[[:space:]]+100\.0%"; then
  ok "Reverts #<pr> counts (case-insensitive)"
else
  fail_msg "Reverts #<pr> counts — output: $out"
fi

# Test 3c: revert of #<pr> lower case also counts.
write_commits <<'JSON'
[{"message":"revert of #11 for bad deploy","date":"2025-01-11T10:00:00Z"}]
JSON
out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -E -q "pi:glm-5.*100\.0%"; then
  ok "revert of #<pr> counts"
else
  fail_msg "revert of #<pr> counts — output: $out"
fi

# Test 4: rate maths is right and worst rate first.
write_prs <<'JSON'
[
  {"number":20,"title":"Feature A","body":"Closes #20\n\nAssisted-by: agent-a:model1","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"},
  {"number":21,"title":"Feature B","body":"Closes #21\n\nAssisted-by: agent-a:model1","mergedAt":"2025-01-11T10:00:00Z","baseRefName":"main"},
  {"number":22,"title":"Feature C","body":"Closes #22\n\nAssisted-by: agent-b:model2","mergedAt":"2025-01-12T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[{"message":"Revert \"Feature A\"","date":"2025-01-12T10:00:00Z"}]
JSON
write_files 20 <<'JSON'
["src/x.txt"]
JSON
write_files 21 <<'JSON'
["src/y.txt"]
JSON
write_files 22 <<'JSON'
["src/z.txt"]
JSON

out=$(run owner/repo --since 2025-01-01 --window-days 7)
# agent-a should have 2 merged 1 defect 50%, agent-b 1 merged 0 defects 0%
if echo "$out" | grep -E -q "agent-a:model1.*2.*1.*50\.0%"; then
  ok "rate maths 50% for agent-a"
else
  fail_msg "rate maths 50% for agent-a — output: $out"
fi
if echo "$out" | grep -E -q "agent-b:model2.*1.*0.*0\.0%"; then
  ok "rate maths 0% for agent-b"
else
  fail_msg "rate maths 0% for agent-b — output: $out"
fi
# Check ordering worst first: agent-a line should appear before agent-b.
line_a=$(echo "$out" | grep -n "agent-a:model1" | cut -d: -f1)
line_b=$(echo "$out" | grep -n "agent-b:model2" | cut -d: -f1)
if [[ -n "$line_a" && -n "$line_b" && "$line_a" -lt "$line_b" ]]; then
  ok "worst rate first"
else
  fail_msg "worst rate first — lines a=$line_a b=$line_b output: $out"
fi
# Check TOTAL row
if echo "$out" | grep -q "TOTAL" && echo "$out" | grep -E -q "TOTAL.*3.*1.*33\.3%"; then
  ok "TOTAL row correct (3 merged 1 defect 33.3%)"
else
  fail_msg "TOTAL row correct — output: $out"
fi

# Test 5: hotfix PR touching same files counts as defect (title fix).
write_prs <<'JSON'
[
  {"number":30,"title":"Add widget","body":"Closes #100\n\nAssisted-by: agent-a:model1","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"},
  {"number":31,"title":"fix widget crash","body":"Fixes #100","mergedAt":"2025-01-12T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[]
JSON
write_files 30 <<'JSON'
["src/widget.txt"]
JSON
write_files 31 <<'JSON'
["src/widget.txt"]
JSON

out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -E -q "agent-a:model1.*1.*1.*100\.0%"; then
  ok "hotfix touching same files counts"
else
  fail_msg "hotfix touching same files counts — output: $out"
fi

# Same but outside window should not count.
write_prs <<'JSON'
[
  {"number":30,"title":"Add widget","body":"Closes #100\n\nAssisted-by: agent-a:model1","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"},
  {"number":31,"title":"fix widget crash","body":"Fixes #100","mergedAt":"2025-01-20T10:00:00Z","baseRefName":"main"}
]
JSON
# files same
out=$(run owner/repo --since 2025-01-01 --window-days 7)
if echo "$out" | grep -E -q "agent-a:model1.*1.*0.*0\.0%"; then
  ok "hotfix outside window does not count"
else
  fail_msg "hotfix outside window does not count — output: $out"
fi

# Test 6: --json prints valid JSON and nothing else on stdout.
write_prs <<'JSON'
[
  {"number":40,"title":"Thing","body":"Assisted-by: a:b","mergedAt":"2025-01-10T10:00:00Z","baseRefName":"main"}
]
JSON
write_commits <<'JSON'
[]
JSON
write_files 40 <<'JSON'
["a.txt"]
JSON
out=$(run owner/repo --since 2025-01-01 --json)
if echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)'; then
  ok "--json prints valid JSON"
else
  fail_msg "--json prints valid JSON — got: $out"
fi

echo "---"
echo "$pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
