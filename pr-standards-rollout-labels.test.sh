#!/bin/bash
# The report must distinguish a missing file from a present file with stale
# managed content, so operators can choose one repair PR instead of a file sweep.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/pr-standards-rollout-labels.sh"

fail=0
check() {
  local name="$1" missing="$2" stale="$3" expected="$4" got
  got=$(build_repair_labels "$missing" "$stale")
  if [ "$got" = "$expected" ]; then
    printf 'ok    %s: %s\n' "$name" "$got"
  else
    printf 'FAIL  %s: expected %s, got %s\n' "$name" "$expected" "$got"
    fail=1
  fi
}

check "absent file only" ".github/pull_request_template.md " "" \
  "missing: .github/pull_request_template.md"
check "stale block only" "" "AGENTS.md " \
  "stale: AGENTS.md"
check "both at once" ".github/pull_request_template.md " "AGENTS.md " \
  "missing: .github/pull_request_template.md; stale: AGENTS.md"

if [ "$fail" -eq 0 ]; then
  echo "all passing"
fi
exit "$fail"
