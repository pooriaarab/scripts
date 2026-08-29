#!/bin/bash
# The repair path picks the branch it will write four managed files into. Matching
# on startswith/endswith alone accepted a hand-made cr-cleanup-adopt-pr-standard,
# and the open-PR check that follows only proves a PR exists, not that this tool
# created it -- so the rollout would write into somebody else's pull request.
set -uo pipefail
PATTERN=$(grep -o 'select(test(\\"[^"]*\\"))' ../scripts-pr-rollout/pr-standards-rollout 2>/dev/null \
  || grep -o 'select(test(\\\\"[^\\\\]*\\\\"))' pr-standards-rollout)
fail=0
check() {
  local branch="$1" want="$2"
  got=$(printf '[{"name":"%s"}]' "$branch" | jq -r ".[].name | select(test(\"^cr-[0-9]+-adopt-pr-standard$\"))")
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
grep -q 'select(test(' pr-standards-rollout || { echo "  FAIL rollout no longer uses an anchored test()"; fail=1; }
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
