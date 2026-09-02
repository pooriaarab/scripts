#!/usr/bin/env bash
# Offline tests for fleet-ci-census. Stub gh on PATH with a recorded fixture.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/fleet-ci-census"
FAKE_ROOT=$(mktemp -d)
FAKE_BIN="$FAKE_ROOT/bin"
FAKE_DATA="$FAKE_ROOT/data"
mkdir -p "$FAKE_BIN" "$FAKE_DATA"
trap 'rm -rf "$FAKE_ROOT"' EXIT

# Recorded Actions payload: two workflows, one failure, one cancel, one 8h
# stuck run that must not enter percentiles, one run missing timestamps,
# one still-in-progress run that must not be counted as if finished.
cat > "$FAKE_DATA/runs.json" <<'JSON'
{"workflow_runs":[
  {"id":1,"name":"oxlint","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:10Z","conclusion":"success"},
  {"id":2,"name":"oxlint","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:20Z","conclusion":"success"},
  {"id":3,"name":"oxlint","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:30Z","conclusion":"success"},
  {"id":4,"name":"oxlint","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:00:40Z","conclusion":"success"},
  {"id":5,"name":"oxlint","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:01:00Z","conclusion":"failure"},
  {"id":6,"name":"CI","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:01:00Z","conclusion":"success"},
  {"id":7,"name":"CI","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:02:00Z","conclusion":"cancelled"},
  {"id":8,"name":"CI","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:03:00Z","conclusion":"success"},
  {"id":9,"name":"stuck","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T08:00:01Z","conclusion":"cancelled"},
  {"id":10,"name":"broken","updated_at":"2026-08-20T00:00:10Z","conclusion":"success"},
  {"id":11,"name":"CI","status":"in_progress","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:05:00Z","conclusion":null}
]}
JSON
echo '{"billable":{"UBUNTU":{"total_ms":120000}}}' > "$FAKE_DATA/timing.json"
cat > "$FAKE_DATA/repos.json" <<'JSON'
[
  {"full_name":"pooriaarab/archived","archived":true,"pushed_at":"2026-09-01T00:00:00Z"},
  {"full_name":"pooriaarab/newest","archived":false,"pushed_at":"2026-08-20T00:00:00Z"},
  {"full_name":"pooriaarab/older","archived":false,"pushed_at":"2026-01-01T00:00:00Z"}
]
JSON

cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -e
DATA_DIR="${FAKE_DATA_DIR:-/tmp}"
args="$*"
if [[ "$args" == *"/timing"* ]]; then cat "$DATA_DIR/timing.json"; exit 0; fi
if [[ "$args" == *"actions/runs"* ]]; then
  if [[ -f "$DATA_DIR/runs_override.json" ]]; then cat "$DATA_DIR/runs_override.json"; else cat "$DATA_DIR/runs.json"; fi
  exit 0
fi
if [[ "$args" == *"users/"*"/repos"* ]]; then cat "$DATA_DIR/repos.json"; exit 0; fi
echo "unknown gh call: $args" >&2
exit 1
GH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH" FAKE_DATA_DIR="$FAKE_DATA"
run() { "$SCRIPT" "$@"; }

out=$(run --help); rc=$?
if (( rc == 0 )) && echo "$out" | grep -q "Usage: fleet-ci-census"; then
  ok "help prints usage and exits 0"
else
  fail_msg "help prints usage — rc=$rc out=$out"
fi

out=$(run owner/app --days 14 --pages 3)
if echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["page_cap"]==300 and d["max_duration_s"]==21600 and d["timing"] is False
r=d["repos"][0]
assert r["repo"]=="owner/app" and r["runs"]==11 and r["runs_are_floor"] is False
names=[w["name"] for w in r["workflows"]]
assert names==["CI","oxlint"]
ci,ox=r["workflows"]
assert ci["runs"]==3 and ci["p50_s"]==120 and ci["p95_s"]==180
assert ci["total_min"]==6 and ci["fail_pct"]==0 and ci["cancelled_pct"]==33
assert ox["runs"]==5 and ox["p50_s"]==30 and ox["p95_s"]==60
assert ox["total_min"]==3 and ox["fail_pct"]==20 and ox["cancelled_pct"]==0
assert r["total_min"]==9
'; then
  ok "JSON groups, sorts, rates, and clamps the 8h outlier"
else
  fail_msg "JSON aggregation — out=$out"
fi

out=$(run owner/app --markdown --pages 3)
if echo "$out" | grep -q "Page cap: 300" \
  && echo "$out" | grep -F "| owner/app | CI | 3 | 120 | 180 | 6 | 0 | 33 |" >/dev/null \
  && echo "$out" | grep -F "| owner/app | oxlint | 5 | 30 | 60 | 3 | 20 | 0 |" >/dev/null \
  && ! echo "$out" | grep -F "owner/app (floor)" >/dev/null \
  && ! echo "$out" | grep -q stuck; then
  ok "markdown ranked by total minutes"
else
  fail_msg "markdown table — out=$out"
fi

python3 -c 'import json,sys; json.dump({"workflow_runs":[{"id":i+1,"name":"CI","run_started_at":"2026-08-20T00:00:00Z","updated_at":"2026-08-20T00:01:00Z","conclusion":"success"} for i in range(100)]}, open(sys.argv[1],"w"))' "$FAKE_DATA/runs_override.json"
out=$(run owner/busy --pages 1)
md=$(run owner/busy --pages 1 --markdown)
if echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["repos"][0]; assert d["page_cap"]==100 and r["runs"]==100 and r["runs_are_floor"] is True' \
  && echo "$md" | grep -q "owner/busy (floor)" \
  && echo "$md" | grep -q "understate the window"; then
  ok "page cap is marked as a floor in JSON and markdown"
else
  fail_msg "floor mark — json=$out md=$md"
fi
rm -f "$FAKE_DATA/runs_override.json"

err=$(run owner/app --timing --pages 3 2>&1 >/dev/null)
out=$(run owner/app --timing --pages 3 2>/dev/null)
if echo "$err" | grep -q "warning: --timing costs one API request per run" \
  && echo "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["timing"] is True
r=d["repos"][0]
assert r["billable_min"]==16
by={w["name"]:w for w in r["workflows"]}
assert by["oxlint"]["billable_min"]==10 and by["CI"]["billable_min"]==6
'; then
  ok "--timing warns and adds billable minutes"
else
  fail_msg "--timing — err=$err out=$out"
fi

out=$(run --limit 26 --pages 1 2>/dev/null)
if echo "$out" | python3 -c '
import json,sys
names=[r["repo"] for r in json.load(sys.stdin)["repos"]]
assert "pooriaarab/archived" not in names
assert set(names)=={"pooriaarab/newest","pooriaarab/older"}
'; then
  ok "discovers newest pushedAt repos and skips archived"
else
  fail_msg "discovery — out=$out"
fi

out=$(run --nope owner/app 2>&1); rc=$?
if (( rc == 2 )) && echo "$out" | grep -q "unknown flag"; then
  ok "unknown flag exits 2"
else
  fail_msg "unknown flag — rc=$rc out=$out"
fi

echo "---"
echo "$pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
