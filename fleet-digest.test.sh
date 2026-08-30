#!/usr/bin/env bash
# Tests for fleet-digest. Runs offline with a fake gh on PATH.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/fleet-digest"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

# Helper: create a temp dir with a fake gh. Caller sets FAKE_BODY etc via env or files.
# Fake gh handles all fleet-digest endpoints by inspecting "$*".
# It reads pre-written JSON files from $FAKE_DATA_DIR if set.

make_fake_gh() {
  local bindir="$1"
  local data_dir="$2"
  mkdir -p "$bindir" "$data_dir"
  cat > "$bindir/gh" <<'FAKESH'
#!/usr/bin/env bash
set -uo pipefail
DATA_DIR="${FAKE_DATA_DIR:-/tmp}"
ARGS="$*"
# Handle gh auth status if ever called (fleet-digest does not call it, but be safe)
if [[ "$ARGS" == *"auth status"* ]]; then
  exit 0
fi
# users/<owner>/repos -> list repos
if [[ "$ARGS" == *"users/"*"/repos"* ]]; then
  page1="[]"
  if [[ -f "$DATA_DIR/user_repos.json" ]]; then page1=$(cat "$DATA_DIR/user_repos.json"); fi
  if [[ "$ARGS" == *"--slurp"* ]]; then
    if [[ -f "$DATA_DIR/user_repos_page2.json" ]]; then
      printf '[%s,%s]' "$page1" "$(cat "$DATA_DIR/user_repos_page2.json")"
    else
      printf '[%s]' "$page1"
    fi
  else
    printf '%s' "$page1"
  fi
  exit 0
fi
# contents/.github/pr-standards.json
if [[ "$ARGS" == *"contents/.github/pr-standards.json"* ]]; then
  # repo name is in ARGS; check if we have a per-repo file
  # Extract repo: look for repos/<owner>/<repo>/contents
  # Use data file if exists, else succeed if data_dir has marker
  if [[ -f "$DATA_DIR/has_standards" ]]; then
    cat "$DATA_DIR/has_standards"
    exit 0
  fi
  # Default: succeed (repo has standards)
  echo '{"name":"pr-standards.json","sha":"abc","content":"e30="}'
  exit 0
fi
# actions/runs?branch=
if [[ "$ARGS" == *"actions/runs"* ]]; then
  if [[ -f "$DATA_DIR/latest_run.json" ]]; then cat "$DATA_DIR/latest_run.json"; else echo '{"workflow_runs":[]}'; fi
  exit 0
fi
# repos/<owner>/<repo> default_branch (with --jq)
if [[ "$ARGS" == *"repos/"* ]] && [[ "$ARGS" == *"--jq"* ]] && [[ "$ARGS" == *"default_branch"* ]]; then
  if [[ -f "$DATA_DIR/repo_details.json" ]]; then
    # If file contains JSON with default_branch, extract it
    python3 -c 'import json; print(json.load(open("'"$DATA_DIR/repo_details.json"'")).get("default_branch","main"))' 2>/dev/null || echo "main"
  else
    echo "main"
  fi
  exit 0
fi
# repos/<owner>/<repo> without query -> repo details
if [[ "$ARGS" =~ repos/[^/]+/[^/?\ ]+$ ]] || [[ "$ARGS" =~ repos/[^/]+/[^/?\ ]+\ +--jq ]]; then
  # This is the repo details call; if it wasn't caught by --jq branch above, handle
  if [[ -f "$DATA_DIR/repo_details.json" ]]; then cat "$DATA_DIR/repo_details.json"; else echo '{"default_branch":"main","archived":false}'; fi
  exit 0
fi
# pulls?state=open
if [[ "$ARGS" == *"pulls?state=open"* ]]; then
  if [[ -f "$DATA_DIR/fail_open_prs" ]]; then exit 1; fi
  page1="[]"
  if [[ -f "$DATA_DIR/open_prs.json" ]]; then page1=$(cat "$DATA_DIR/open_prs.json"); fi
  if [[ "$ARGS" == *"--slurp"* ]]; then
    if [[ -f "$DATA_DIR/open_prs_page2.json" ]]; then
      printf '[%s,%s]' "$page1" "$(cat "$DATA_DIR/open_prs_page2.json")"
    else
      printf '[%s]' "$page1"
    fi
  else
    printf '%s' "$page1"
  fi
  exit 0
fi
# pulls/<num>/reviews
if [[ "$ARGS" == *"pulls/"*"/reviews"* ]]; then
  # Extract pr number if possible
  # Try to find a per-PR file
  num=$(echo "$ARGS" | python3 -c 'import re,sys; m=re.search(r"pulls/(\d+)/reviews", sys.stdin.read()); print(m.group(1) if m else "")' 2>/dev/null || echo "")
  if [[ -n "$num" && -f "$DATA_DIR/reviews_${num}.json" ]]; then
    cat "$DATA_DIR/reviews_${num}.json"
  elif [[ -f "$DATA_DIR/reviews.json" ]]; then
    cat "$DATA_DIR/reviews.json"
  else
    echo "[]"
  fi
  exit 0
fi
# commits/<sha>/check-runs
if [[ "$ARGS" == *"check-runs"* ]]; then
  sha=$(echo "$ARGS" | python3 -c 'import re,sys; m=re.search(r"commits/([^/]+)/check", sys.stdin.read()); print(m.group(1) if m else "")' 2>/dev/null || echo "")
  page1='{"check_runs":[]}'
  if [[ -n "$sha" && -f "$DATA_DIR/checks_${sha}.json" ]]; then
    page1=$(cat "$DATA_DIR/checks_${sha}.json")
  elif [[ -f "$DATA_DIR/checks.json" ]]; then
    page1=$(cat "$DATA_DIR/checks.json")
  fi
  if [[ "$ARGS" == *"--slurp"* ]]; then
    if [[ -n "$sha" && -f "$DATA_DIR/checks_${sha}_page2.json" ]]; then
      printf '[%s,%s]' "$page1" "$(cat "$DATA_DIR/checks_${sha}_page2.json")"
    else
      printf '[%s]' "$page1"
    fi
  else
    printf '%s' "$page1"
  fi
  exit 0
fi
# commits/<sha>/status
if [[ "$ARGS" == *"commits/"*"/status"* ]]; then
  if [[ -f "$DATA_DIR/status.json" ]]; then cat "$DATA_DIR/status.json"; else echo '{"state":""}'; fi
  exit 0
fi
# Fallback
echo "[]"
exit 0
FAKESH
  chmod +x "$bindir/gh"
}

run_with_fake() {
  local bindir="$1"
  shift
  FAKE_DATA_DIR="$2" PATH="$bindir:$PATH" "$@"
}

# Test: --help prints usage and exits 0
# A queued check is not a green check. A stuck third-party app sat QUEUED for
# hours while a commit status said success; reading the status alone sent a
# person to a pull request whose own CI had not spoken.
test_queued_is_not_green() {
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  now=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  cat > "$datadir/open_prs.json" <<JSON
[
  {
    "number": 50,
    "title": "Waiting on a stuck app",
    "body": "Closes #50 normal body",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/50",
    "labels": [],
    "created_at": "$now",
    "updated_at": "$now",
    "draft": false,
    "head": {"sha": "queued1"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_50.json"
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"stuck app","status":"queued","conclusion":null}]}' > "$datadir/checks_queued1.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1)
  if echo "$out" | grep -q "Nothing needs you."; then
    pass "a queued check keeps a PR out of the ready list"
  else
    fail "a queued check keeps a PR out of the ready list" "out=$out"
  fi
  rm -rf "$td"
}

# A pull request with no check runs at all is unknown, not green: CI has
# usually not started. Sending a person there wastes the one thing the digest
# is protecting.
test_no_checks_is_not_green() {
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  now=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  cat > "$datadir/open_prs.json" <<JSON
[
  {
    "number": 51,
    "title": "CI has not started",
    "body": "Closes #51 normal body",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/51",
    "labels": [],
    "created_at": "$now",
    "updated_at": "$now",
    "draft": false,
    "head": {"sha": "nochk1"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_51.json"
  echo '{"check_runs":[]}' > "$datadir/checks_nochk1.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1)
  if echo "$out" | grep -q "Nothing needs you."; then
    pass "a PR with no check runs is not called ready"
  else
    fail "a PR with no check runs is not called ready" "out=$out"
  fi
  rm -rf "$td"
}

# One line per pull request. A PR already listed for a missing label does not
# need a second line telling the same reader to look at the same PR.
test_one_line_per_pr() {
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  now=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  cat > "$datadir/open_prs.json" <<JSON
[
  {
    "number": 52,
    "title": "Oversized and green",
    "body": "Please add the oversized-approved label",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/52",
    "labels": [],
    "created_at": "$now",
    "updated_at": "$now",
    "draft": false,
    "head": {"sha": "both01"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_52.json"
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' > "$datadir/checks_both01.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1)
  count=$(echo "$out" | grep -c "PR #52")
  if [ "$count" = "1" ]; then
    pass "a PR appears on exactly one line"
  else
    fail "a PR appears on exactly one line" "count=$count out=$out"
  fi
  rm -rf "$td"
}

test_help() {
  local out rc
  out=$("$SCRIPT" --help 2>&1); rc=$?
  if (( rc == 0 )) && echo "$out" | grep -q "Usage: fleet-digest"; then
    pass "help prints usage and exits 0"
  else
    fail "help prints usage and exits 0" "rc=$rc out=$out"
  fi
}

# Test: empty fleet prints Nothing needs you. and exits 0
test_empty() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  # Empty PRs and no failing CI
  echo "[]" > "$datadir/open_prs.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  echo '{"default_branch":"main","archived":false}' > "$datadir/repo_details.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-empty 2>&1); rc=$?
  if (( rc == 0 )) && echo "$out" | grep -q "Nothing needs you."; then
    pass "empty fleet prints Nothing needs you."
  else
    fail "empty fleet prints Nothing needs you." "rc=$rc out=$out"
  fi
  rm -rf "$td"
}

# Test: PR requesting missing owner-only label appears
test_label_missing() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 42,
    "title": "Fix onboarding drop-off",
    "body": "Closes #42\n\nSay why here and ask for the `oversized-approved` label.",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/42",
    "labels": [],
    "created_at": "2026-08-10T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "abc123"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_42.json"
  echo '{"check_runs":[]}' > "$datadir/checks_abc123.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "oversized-approved" && echo "$out" | grep -q "https://github.com/pooriaarab/repo-a/pull/42"; then
    pass "PR requesting missing label appears"
  else
    fail "PR requesting missing label appears" "out=$out"
  fi
  rm -rf "$td"
}

# Test: PR that already carries the label does not appear
test_label_present() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 43,
    "title": "Large change",
    "body": "Ask for oversized-approved label here",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/43",
    "labels": [{"name": "oversized-approved"}],
    "created_at": "2026-08-10T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "def456"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_43.json"
  echo '{"check_runs":[]}' > "$datadir/checks_def456.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "Nothing needs you."; then
    pass "PR that already carries the label does not appear"
  else
    fail "PR that already carries the label does not appear" "out=$out"
  fi
  rm -rf "$td"
}

# Test: fresh PR is not stale
test_fresh_not_stale() {
  local td bindir datadir out rc now fresh
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  now=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  # created_at 1 hour ago, updated_at now
  fresh=$(python3 -c "
from datetime import datetime, timezone, timedelta
now=datetime.now(timezone.utc)
print((now - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
  cat > "$datadir/open_prs.json" <<JSON
[
  {
    "number": 44,
    "title": "Fresh PR",
    "body": "Closes #44 normal body",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/44",
    "labels": [],
    "created_at": "$fresh",
    "updated_at": "$now",
    "draft": false,
    "head": {"sha": "fresh99"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_44.json"
  echo '{"check_runs":[]}' > "$datadir/checks_fresh99.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a --stale-days 3 2>&1); rc=$?
  if echo "$out" | grep -q "is stale"; then
    fail "fresh PR is not stale" "fresh PR incorrectly marked stale: out=$out"
  else
    pass "fresh PR is not stale"
  fi
  rm -rf "$td"
}

# Test: stale PR is reported
test_stale_detected() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 45,
    "title": "Old PR",
    "body": "Closes #45",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/45",
    "labels": [],
    "created_at": "2026-01-01T10:00:00Z",
    "updated_at": "2026-01-02T10:00:00Z",
    "draft": false,
    "head": {"sha": "oldsha"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_45.json"
  echo '{"check_runs":[]}' > "$datadir/checks_oldsha.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a --stale-days 3 2>&1); rc=$?
  if echo "$out" | grep -q "is stale" && echo "$out" | grep -q "pull/45"; then
    pass "stale PR is reported"
  else
    fail "stale PR is reported" "out=$out"
  fi
  rm -rf "$td"
}

# Test: --json prints valid JSON with expected keys
test_json() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 50,
    "title": "Needs label",
    "body": "ask for proof-not-applicable",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/50",
    "labels": [],
    "created_at": "2026-08-10T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "jsha"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_50.json"
  echo '{"check_runs":[]}' > "$datadir/checks_jsha.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a --json 2>&1); rc=$?
  if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "label_requests" in d' <<< "$out" 2>/dev/null; then
    pass "--json prints valid JSON"
  else
    fail "--json prints valid JSON" "out=$out"
  fi
  rm -rf "$td"
}

# Test: empty fleet --json prints valid JSON with empty arrays
test_empty_json() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  echo "[]" > "$datadir/open_prs.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-empty --json 2>&1); rc=$?
  if python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d.get("label_requests")==[] and d.get("stale_prs")==[]' <<< "$out" 2>/dev/null; then
    pass "empty fleet --json prints empty arrays"
  else
    fail "empty fleet --json prints empty arrays" "out=$out"
  fi
  rm -rf "$td"
}

# Test: proof-not-applicable label request
test_proof_label() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 51,
    "title": "Docs change",
    "body": "This needs proof-not-applicable",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/51",
    "labels": [],
    "created_at": "2026-08-10T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "psha"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_51.json"
  echo '{"check_runs":[]}' > "$datadir/checks_psha.json"
  echo '{"state":""}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "proof-not-applicable"; then
    pass "proof-not-applicable request appears"
  else
    fail "proof-not-applicable request appears" "out=$out"
  fi
  rm -rf "$td"
}

# gh api --paginate (without --slurp) would emit each page as its own JSON
# array, which is not valid JSON to a single json.loads. This checks that
# a two-page result for open PRs is actually merged, not just parsed without
# crashing: a PR that only exists on the second page must still show up.
test_paginated_prs_are_merged() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 60,
    "title": "First page PR",
    "body": "Closes #60",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/60",
    "labels": [],
    "created_at": "2026-08-28T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "pg60sha"}
  }
]
JSON
  cat > "$datadir/open_prs_page2.json" <<'JSON'
[
  {
    "number": 61,
    "title": "Second page PR",
    "body": "Closes #61",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/61",
    "labels": [],
    "created_at": "2026-08-28T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "pg61sha"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_60.json"
  echo "[]" > "$datadir/reviews_61.json"
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' > "$datadir/checks_pg60sha.json"
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' > "$datadir/checks_pg61sha.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "PR #60" && echo "$out" | grep -q "PR #61"; then
    pass "a second page of open PRs is not dropped"
  else
    fail "a second page of open PRs is not dropped" "rc=$rc out=$out"
  fi
  rm -rf "$td"
}

# A PR with a review that requested changes is waiting on its author, not on
# a human decision about green checks, so it must not be reported ready.
test_changes_requested_not_ready() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 62,
    "title": "Green but changes requested",
    "body": "Closes #62",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/62",
    "labels": [],
    "created_at": "2026-08-28T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "cr62sha"}
  }
]
JSON
  cat > "$datadir/reviews_62.json" <<'JSON'
[
  {"state": "CHANGES_REQUESTED", "submitted_at": "2026-08-29T10:00:00Z"}
]
JSON
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' > "$datadir/checks_cr62sha.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "Nothing needs you."; then
    pass "a PR with changes requested is not reported ready"
  else
    fail "a PR with changes requested is not reported ready" "rc=$rc out=$out"
  fi
  rm -rf "$td"
}

# A commit with more than one page of check runs must have every page's
# runs considered: a failing run stuck on the second page must still keep
# the PR out of the ready list, not just whatever ran completed() on page 1.
test_paginated_check_runs_are_merged() {
  local td bindir datadir out rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  cat > "$datadir/open_prs.json" <<'JSON'
[
  {
    "number": 70,
    "title": "Looks green on page one",
    "body": "Closes #70",
    "html_url": "https://github.com/pooriaarab/repo-a/pull/70",
    "labels": [],
    "created_at": "2026-08-28T10:00:00Z",
    "updated_at": "2026-08-28T10:00:00Z",
    "draft": false,
    "head": {"sha": "pgchk70"}
  }
]
JSON
  echo "[]" > "$datadir/reviews_70.json"
  echo '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' > "$datadir/checks_pgchk70.json"
  echo '{"check_runs":[{"name":"slow-matrix-job","status":"completed","conclusion":"failure"}]}' > "$datadir/checks_pgchk70_page2.json"
  echo '{"state":"success"}' > "$datadir/status.json"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>&1); rc=$?
  if echo "$out" | grep -q "Nothing needs you."; then
    pass "a failing check run on a second page keeps a PR out of the ready list"
  else
    fail "a failing check run on a second page keeps a PR out of the ready list" "rc=$rc out=$out"
  fi
  rm -rf "$td"
}

# A gh api call that fails outright (bad auth, network error) must not be
# indistinguishable from a repo that genuinely has nothing to report: it
# should surface as a non-zero exit and a warning, not "Nothing needs you.".
test_gh_api_failure_is_not_silent() {
  local td bindir datadir out err rc
  td=$(mktemp -d); bindir="$td/bin"; datadir="$td/data"
  make_fake_gh "$bindir" "$datadir"
  echo '{"workflow_runs":[]}' > "$datadir/latest_run.json"
  touch "$datadir/fail_open_prs"
  out=$(FAKE_DATA_DIR="$datadir" PATH="$bindir:$PATH" "$SCRIPT" --repos pooriaarab/repo-a 2>"$td/stderr"); rc=$?
  err=$(cat "$td/stderr")
  if (( rc != 0 )) && echo "$err" | grep -qi "warning"; then
    pass "a failed gh api call is reported, not treated as an empty fleet"
  else
    fail "a failed gh api call is reported, not treated as an empty fleet" "rc=$rc out=$out err=$err"
  fi
  rm -rf "$td"
}

test_help
test_empty
test_label_missing
test_label_present
test_fresh_not_stale
test_stale_detected
test_json
test_empty_json
test_proof_label
test_queued_is_not_green
test_no_checks_is_not_green
test_one_line_per_pr
test_paginated_prs_are_merged
test_changes_requested_not_ready
test_paginated_check_runs_are_merged
test_gh_api_failure_is_not_silent

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then exit 1; fi
