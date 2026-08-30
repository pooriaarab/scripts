#!/bin/bash
# The rollout's own pull request must pass the check the rollout installs.
# It did not: the hardcoded "## How I verified" said the PR obeys the rule and
# named no command, so content-rabbit #998 -- the first real run -- opened red
# on the very check it was installing.
#
# Build the body the same way the rollout does, from the same strings in the
# same file, and hand it to the real validateBody. A hand-copied body would keep
# passing after someone edits the real one, which is the bug this test exists
# to catch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROLLOUT="$HERE/pr-standards-rollout"

OWNER=pooriaarab
repo=content-rabbit
PREFIX=cr
PREFIX_UPPER=CR
ISSUE_NUM=997
BRANCH="$PREFIX-$ISSUE_NUM-adopt-pr-standard"
DEFAULT_BRANCH=main

# Take the rollout's real precheck block and body, and run them. sed carves out
# the region between the two markers so the test cannot drift from the source.
eval "$(sed -n '/^  # The PR that installs the standard has to obey it/,/^  gh pr create/p' "$ROLLOUT" \
  | sed '/^  gh pr create/d; /^    continue$/d; /^  fi$/d; /^  if \[ "\$PRECHECK_STATUS"/,/fail_c=/d')"

BODY=$(sed -n '/^    --body "Closes #\$ISSUE_NUM/,/^Assisted-by: pooriaarab\/scripts:pr-standards-rollout" \\$/p' "$ROLLOUT" \
  | sed '1s/^    --body "//; $s/" \\$//')
BODY=$(eval "cat <<ROLLOUT_BODY_EOF
$BODY
ROLLOUT_BODY_EOF")

fail=0
say() { if [ "$1" = 0 ]; then printf 'ok    %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; fail=1; fi; }

case "$BODY" in
  *"PASS  branch name: $BRANCH"*) say 0 'the body carries the precheck output, not a claim about it' ;;
  *) say 1 'the body carries the precheck output, not a claim about it'; printf '%s\n' "$BODY" ;;
esac

# The authority, not a regex that guesses at it. cd into $HERE first: node
# resolves a relative import in an -e/--input-type=module script against the
# process's cwd, not the script's own directory, so running this test via an
# absolute path from anywhere else would fail to find pr-standards.mjs.
(cd "$HERE" && GITHUB_REPOSITORY="$OWNER/$repo" BODY="$BODY" node --input-type=module -e '
import { validateBody, DEFAULT_CONFIG } from "./pr-standards.mjs";
const result = validateBody(process.env.BODY, 997, { ...DEFAULT_CONFIG, prefix: "cr" });
for (const failure of result.failures) console.log(`      ${failure.check}: ${failure.got}`);
process.exit(result.ok ? 0 : 1);
')
say $? 'validateBody accepts the body the rollout opens'

[ $fail -eq 0 ] && echo && echo "all passing"
exit $fail
