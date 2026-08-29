#!/bin/bash
# The repair path picks the branch it will write four managed files into. Matching
# on startswith/endswith alone accepted a hand-made cr-cleanup-adopt-pr-standard,
# and the open-PR check that follows only proves a PR exists, not that this tool
# created it -- so the rollout would write into somebody else's pull request.
set -uo pipefail
# Extract the actual jq filter from the rollout script and use it below, rather
# than a hand-copied duplicate -- a duplicate would keep passing after someone
# edits the real regex in pr-standards-rollout (e.g. drops the anchors), which
# is exactly the class of bug this test exists to catch.
RAW=$(grep -o 'select(test(\\"[^)]*\\"))' pr-standards-rollout) || {
  echo "  FAIL cannot find the branch-match filter in pr-standards-rollout"
  exit 1
}
# Swap in a concrete prefix and turn the shell-escaped \" back into a bare "
# -- $PATTERN is expanded into a jq filter below, and unlike a literal \" in
# script source, a variable's own backslash-quote bytes pass through as-is.
PATTERN=$(printf '%s' "$RAW" | sed 's/\${PREFIX}/cr/; s/\\"/"/g')
fail=0
check() {
  local branch="$1" want="$2"
  got=$(printf '[{"name":"%s"}]' "$branch" | jq -r ".[].name | $PATTERN")
  if [ "$want" = yes ] && [ -z "$got" ]; then echo "  FAIL $branch should match"; fail=1
  elif [ "$want" = no ] && [ -n "$got" ]; then echo "  FAIL $branch should not match"; fail=1
  else echo "  OK   $branch"; fi
}
check "cr-142-adopt-pr-standard" yes
check "cr-cleanup-adopt-pr-standard" no
check "cr--adopt-pr-standard" no
check "cr-142-adopt-pr-standard-extra" no
check "xcr-142-adopt-pr-standard" no
check "main" no
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
