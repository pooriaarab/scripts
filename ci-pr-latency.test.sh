#!/usr/bin/env bash
# E2E tests for ci-pr-latency --workflow sampling. Stubs `gh` on PATH with a
# recorded-style fixture: 10 completed pull_request runs, newest first, where
# only 3 are named unit-tests (positions 8-10). --limit 8 must still sample all
# 3 matching runs, not just the 1 inside the unfiltered window.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/ci-pr-latency"
FAKE_ROOT=$(mktemp -d)
FAKE_BIN="$FAKE_ROOT/bin"
FAKE_DATA="$FAKE_ROOT/data"
mkdir -p "$FAKE_BIN" "$FAKE_DATA"
trap 'rm -rf "$FAKE_ROOT"' EXIT

cat > "$FAKE_DATA/workflows.json" <<'JSON'
{"total_count":3,"workflows":[
  {"id":11,"name":"lint","path":".github/workflows/lint.yml"},
  {"id":12,"name":"docs","path":".github/workflows/docs.yml"},
  {"id":13,"name":"unit-tests","path":".github/workflows/unit-tests.yml"}
]}
JSON
cat > "$FAKE_DATA/runs.json" <<'JSON'
{"total_count":10,"workflow_runs":[
  {"id":110,"name":"lint","created_at":"2026-09-10T00:00:00Z"},
  {"id":109,"name":"docs","created_at":"2026-09-09T00:00:00Z"},
  {"id":108,"name":"e2e","created_at":"2026-09-08T00:00:00Z"},
  {"id":107,"name":"lint","created_at":"2026-09-07T00:00:00Z"},
  {"id":106,"name":"docs","created_at":"2026-09-06T00:00:00Z"},
  {"id":105,"name":"lint","created_at":"2026-09-05T00:00:00Z"},
  {"id":104,"name":"docs","created_at":"2026-09-04T00:00:00Z"},
  {"id":103,"name":"unit-tests","created_at":"2026-09-03T00:00:00Z"},
  {"id":102,"name":"unit-tests","created_at":"2026-08-20T00:00:00Z"},
  {"id":101,"name":"unit-tests","created_at":"2026-08-10T00:00:00Z"}
]}
JSON
python3 - "$FAKE_DATA" <<'PY'
import json, sys
d = sys.argv[1]
# machine 100/180/260s, latency 120/200/300s for the three matching runs
jobs = {
    103: ("2026-09-03T00:00:20Z", "2026-09-03T00:02:00Z"),
    102: ("2026-08-20T00:00:20Z", "2026-08-20T00:03:20Z"),
    101: ("2026-08-10T00:00:40Z", "2026-08-10T00:05:00Z"),
}
for rid, (s, e) in jobs.items():
    json.dump({"jobs": [{"name": "build", "started_at": s, "completed_at": e,
                          "labels": ["ubuntu-latest"]}]},
              open(f"{d}/jobs_{rid}.json", "w"))
for rid, day in [(110, 10), (109, 9), (108, 8), (107, 7), (106, 6), (105, 5), (104, 4)]:
    dd = f"2026-09-{day:02d}"
    json.dump({"jobs": [{"name": "build", "started_at": f"{dd}T00:00:00Z",
                          "completed_at": f"{dd}T00:01:00Z", "labels": ["ubuntu-latest"]}]},
              open(f"{d}/jobs_{rid}.json", "w"))
PY

# Test-double for `gh`: emulates the Actions REST API plus gh's own --jq pass.
# Workflow listing pages at 2 per page so discovery must follow pagination.
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -u
DATA="${FAKE_DATA_DIR:-/tmp}"
echo "$*" >> "${GH_LOG:-/dev/null}"
if [[ "${1:-}" == "auth" ]]; then exit 0; fi
ep=""; jqf=""; prev=""
for a in "$@"; do
  if [[ "$prev" == "--jq" ]]; then jqf="$a"; prev=""; continue; fi
  [[ "$a" == "--jq" ]] && { prev="--jq"; continue; }
  if [[ "$a" != -* && "$a" != "api" && -z "$ep" ]]; then ep="$a"; fi
  prev="$a"
done
perpage=30; [[ "$ep" =~ per_page=([0-9]+) ]] && perpage="${BASH_REMATCH[1]}"
page=1; [[ "$ep" =~ [\?\&]page=([0-9]+) ]] && page="${BASH_REMATCH[1]}"
wf="$DATA/workflows.json"
[[ "${AMBIGUOUS_WORKFLOWS:-0}" == "1" ]] && wf="$DATA/workflows_ambiguous.json"
runs="$DATA/runs.json"
if [[ -n "${LITERAL_WORKFLOW_NAME:-}" ]]; then
  jq --arg n "$LITERAL_WORKFLOW_NAME" '(.workflows[] | select(.id==13) | .name)=$n' "$wf" > "$DATA/workflows_literal.json"
  wf="$DATA/workflows_literal.json"
  jq --arg n "$LITERAL_WORKFLOW_NAME" '(.workflow_runs[] | select(.name=="unit-tests") | .name)=$n' "$runs" > "$DATA/runs_literal.json"
  runs="$DATA/runs_literal.json"
fi
out=""
if [[ "$ep" =~ actions/workflows/([0-9]+)/runs ]]; then
  wid="${BASH_REMATCH[1]}"
  wname=$(jq -r --argjson id "$wid" '.workflows[] | select(.id==$id) | .name' "$wf")
  out=$(jq --arg wname "$wname" --argjson cap "$perpage" \
    '{total_count: ([.workflow_runs[] | select(.name==$wname)] | length),
      workflow_runs: ([.workflow_runs[] | select(.name==$wname)] | .[0:$cap])}' "$runs")
elif [[ "$ep" == *"actions/workflows"* ]]; then
  start=$(( (page-1)*2 ))
  out=$(jq --argjson s "$start" '{total_count: .total_count, workflows: (.workflows | .[$s:$s+2])}' "$wf")
elif [[ "$ep" =~ actions/runs/([0-9]+)/jobs ]]; then
  out="$(cat "$DATA/jobs_${BASH_REMATCH[1]}.json")"
elif [[ "$ep" == *"actions/runs"* ]]; then
  out=$(jq --argjson n "$perpage" '{total_count: .total_count, workflow_runs: (.workflow_runs | .[0:$n])}' "$DATA/runs.json")
else
  echo "unknown gh call: $*" >&2; exit 1
fi
if [[ -n "$jqf" ]]; then printf '%s' "$out" | jq -r "$jqf"
else printf '%s' "$out"; fi
GH
chmod +x "$FAKE_BIN/gh"
cat > "$FAKE_DATA/workflows_ambiguous.json" <<'JSON'
{"total_count":4,"workflows":[
  {"id":11,"name":"lint","path":".github/workflows/lint.yml"},
  {"id":12,"name":"docs","path":".github/workflows/docs.yml"},
  {"id":13,"name":"unit-tests","path":".github/workflows/unit-tests.yml"},
  {"id":14,"name":"unit-tests","path":".github/workflows/unit-tests-fork.yml"}
]}
JSON
export PATH="$FAKE_BIN:$PATH" FAKE_DATA_DIR="$FAKE_DATA"
export GH_LOG="$FAKE_ROOT/gh.log"

# 1. --limit counts matching runs, not the unfiltered window.
out=$("$SCRIPT" private-repo-0a63/test --limit 8 --workflow unit-tests 2>&1); rc=$?
if (( rc == 0 )) && echo "$out" | grep -q "(3 runs sampled)" \
  && echo "$out" | grep -q "p50   200s" && echo "$out" | grep -q "p95   300s" \
  && echo "$out" | grep -q "MACHINE  p50   180s"; then
  ok "--limit 8 samples all 3 matching runs with corrected percentiles"
else
  fail_msg "filtered text sample — rc=$rc out: $out"
fi

# 2. JSON shape carries the corrected sample.
out=$("$SCRIPT" private-repo-0a63/test --limit 8 --workflow unit-tests --json 2>/dev/null); rc=$?
if (( rc == 0 )) && echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["runs_sampled"] == 3, d
assert d["latency_p50_s"] == 200, d
assert d["latency_p95_s"] == 300, d
assert d["machine_p50_s"] == 180, d
assert d["machine_seconds_by_tier"] == {"hosted": 540}, d
'; then
  ok "--json reports the corrected sample and tier totals"
else
  fail_msg "filtered json sample — rc=$rc out: $out"
fi

# 3. Filtered mode reads the workflow's own runs, paginates workflow
# discovery, and never touches the unfiltered endpoint.
: > "$GH_LOG"
"$SCRIPT" private-repo-0a63/test --limit 8 --workflow unit-tests >/dev/null 2>&1
log=$(cat "$GH_LOG")
if echo "$log" | grep -q "actions/workflows/13/runs?status=completed&event=pull_request&per_page=8" \
  && echo "$log" | grep -q "actions/workflows?.*page=2" \
  && ! echo "$log" | grep -q "actions/runs?status"; then
  ok "filtered mode uses per-workflow runs, page 2, no unfiltered call"
else
  fail_msg "endpoint routing — log: $log"
fi

# 4. Missing workflow name fails explicitly.
out=$(AMBIGUOUS_WORKFLOWS=0 "$SCRIPT" private-repo-0a63/test --workflow nope 2>&1); rc=$?
if (( rc != 0 )) && echo "$out" | grep -q "no workflow named"; then
  ok "missing workflow name errors explicitly"
else
  fail_msg "missing workflow — rc=$rc out: $out"
fi

# 5. Ambiguous workflow name fails explicitly and lists the matches.
out=$(AMBIGUOUS_WORKFLOWS=1 "$SCRIPT" private-repo-0a63/test --workflow unit-tests 2>&1); rc=$?
if (( rc != 0 )) && echo "$out" | grep -qi "ambiguous" \
  && echo "$out" | grep -q "unit-tests-fork"; then
  ok "ambiguous workflow name errors and lists matches"
else
  fail_msg "ambiguous workflow — rc=$rc out: $out"
fi

# 6. --since still applies on the corrected sample (drops run 101).
out=$("$SCRIPT" private-repo-0a63/test --limit 8 --workflow unit-tests --since 2026-08-15 --json 2>/dev/null); rc=$?
if (( rc == 0 )) && echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["runs_sampled"] == 2, d
assert d["latency_p50_s"] == 120, d
assert d["latency_p95_s"] == 200, d
'; then
  ok "--since filters the corrected sample"
else
  fail_msg "since on filtered sample — rc=$rc out: $out"
fi

# 7. --event passes through to the per-workflow runs call.
: > "$GH_LOG"
"$SCRIPT" private-repo-0a63/test --limit 8 --workflow unit-tests --event push >/dev/null 2>&1; rc=$?
if (( rc == 0 )) && grep -q "actions/workflows/13/runs?status=completed&event=push" "$GH_LOG"; then
  ok "--event reaches the per-workflow runs call"
else
  fail_msg "event passthrough — rc=$rc log: $(cat "$GH_LOG")"
fi

# 8. Unfiltered behavior is unchanged: same endpoint, no workflow lookup.
: > "$GH_LOG"
out=$("$SCRIPT" private-repo-0a63/test --limit 8 2>&1); rc=$?
if (( rc == 0 )) && echo "$out" | grep -q "(8 runs sampled)" \
  && grep -q "actions/runs?status=completed&event=pull_request&per_page=8" "$GH_LOG" \
  && ! grep -q "actions/workflows" "$GH_LOG"; then
  ok "unfiltered mode keeps the old endpoint and no workflow lookup"
else
  fail_msg "unfiltered mode — rc=$rc out: $out log: $(cat "$GH_LOG")"
fi

# Literal names must survive the JSON transport without escape conversion.
out=$(LITERAL_WORKFLOW_NAME='build\tools' "$SCRIPT" private-repo-0a63/test --limit 8 --workflow 'build\tools' --json 2>/dev/null); rc=$?
if (( rc == 0 )) && echo "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["runs_sampled"] == 3'; then
  ok "literal backslashes survive workflow lookup"
else
  fail_msg "literal workflow name — rc=$rc out: $out"
fi

echo "---"
echo "$pass passed, $fail failed"
exit "$(( fail > 0 ))"
