#!/usr/bin/env bash
# Run the check embedded in generated-drift.yml against a throwaway git repo.
#
# The first version of this check read its config through an unexported shell
# variable, so every lookup raised KeyError, every lookup was swallowed, and the
# job passed on every repo without ever running a generator. A check that
# silently never runs is worse than no check, because the green tick is a lie.
# These cases exist to catch that shape of failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the check from the workflow rather than copying it, so the test cannot
# drift from what CI runs.
python3 - "$HERE/generated-drift.yml" "$WORK/check.py" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, line in enumerate(lines) if line.strip() == "python3 <<'PY'") + 1
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "PY")
indent = len(lines[start]) - len(lines[start].lstrip())
open(sys.argv[2], "w").write("\n".join(line[indent:] for line in lines[start:end]) + "\n")
PY

fails=0
check() {
  local want="$1" name="$2" config="$3" got
  rm -rf "$WORK/repo" "$WORK/report.md"
  mkdir -p "$WORK/repo/.github"
  git -C "$WORK/repo" init -q
  git -C "$WORK/repo" config user.email t@t; git -C "$WORK/repo" config user.name t
  printf 'committed\n' > "$WORK/repo/generated.txt"
  [ "$config" = "none" ] || printf '%s' "$config" > "$WORK/repo/.github/pr-standards.json"
  git -C "$WORK/repo" add -A && git -C "$WORK/repo" commit -qm init
  ( cd "$WORK/repo" && REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then printf 'ok    %s\n' "$name"
  else printf 'FAIL  %s (want exit %s, got %s)\n' "$name" "$want" "$got"; fails=$((fails + 1)); fi
}

CLEAN='{"generators":["true"]}'
DIRTY='{"generators":["echo regenerated > generated.txt"]}'
# The generator reads a file only the setup step creates, so this case fails
# unless the setup really ran first.
SETUP='{"generatorSetup":"echo committed > .setup-src","generators":["cp .setup-src generated.txt && rm .setup-src"]}'
BROKEN='{"generators":["exit 3"]}'

check 0 'passes when the repo has no config'          none
check 0 'passes when no generators are configured'    '{"prefix":"scr"}'
check 0 'passes when the generator changes nothing'   "$CLEAN"
check 1 'fails when the generator changes a file'     "$DIRTY"
check 0 'runs generatorSetup before the generators'   "$SETUP"
check 1 'fails when a generator itself fails'         "$BROKEN"

# The report is what the PR comment quotes. An empty one leaves the author with
# a red check and no idea which file to regenerate.
rm -rf "$WORK/repo" "$WORK/report.md"; mkdir -p "$WORK/repo/.github"
git -C "$WORK/repo" init -q; git -C "$WORK/repo" config user.email t@t; git -C "$WORK/repo" config user.name t
printf 'committed\n' > "$WORK/repo/generated.txt"; printf '%s' "$DIRTY" > "$WORK/repo/.github/pr-standards.json"
git -C "$WORK/repo" add -A && git -C "$WORK/repo" commit -qm init
( cd "$WORK/repo" && REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
if grep -q 'generated.txt' "$WORK/report.md" 2>/dev/null; then printf 'ok    %s\n' 'names the drifted file in the report'
else printf 'FAIL  %s\n' 'names the drifted file in the report'; fails=$((fails + 1)); fi

[ "$fails" = 0 ] || { printf '\n%s failing\n' "$fails" >&2; exit 1; }
printf '\nall passing\n'
