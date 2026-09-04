#!/usr/bin/env bash
# Run the check embedded in post-merge-verify.yml against a local server.
#
# The workflow's whole value is that it goes red only when the deploy really
# did not land. A check that cannot tell "no config" from "wrong SHA" would
# either spam issues across the fleet or hide a dead deploy, so both cases are
# pinned here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; kill "${SERVER_PID:-}" 2>/dev/null' EXIT

# Pull the check out of the workflow: the lines between the python heredoc
# markers. Testing a copy would let the copy drift from what CI runs.
python3 - "$HERE/post-merge-verify.yml" "$WORK/check.py" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, line in enumerate(lines) if line.strip() == "python3 <<'PY'") + 1
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "PY")
indent = len(lines[start]) - len(lines[start].lstrip())
open(sys.argv[2], "w").write("\n".join(line[indent:] for line in lines[start:end]) + "\n")
PY

SHA=1111111111111111111111111111111111111111
mkdir -p "$WORK/site"
printf '{"sha": "%s"}' "$SHA" > "$WORK/site/version"
printf '{"sha": null}' > "$WORK/site/version-null"
printf '[1, 2, 3]' > "$WORK/site/version-list"
printf 'ok' > "$WORK/site/index.html"
(cd "$WORK/site" && exec python3 -m http.server 8731 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in $(seq 30); do curl -fs http://127.0.0.1:8731/version >/dev/null 2>&1 && break; sleep 0.2; done

fails=0
check() {
  local want="$1" name="$2" config="$3" expected="$4" got
  mkdir -p "$WORK/repo/.github"
  if [ "$config" = "none" ]; then rm -f "$WORK/repo/.github/pr-standards.json"; else printf '%s' "$config" > "$WORK/repo/.github/pr-standards.json"; fi
  rm -f "$WORK/report.md"
  ( cd "$WORK/repo" && EXPECTED_SHA="$expected" REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then printf 'ok    %s\n' "$name"
  else printf 'FAIL  %s (want exit %s, got %s)\n' "$name" "$want" "$got"; fails=$((fails + 1)); fi
}

LIVE='{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":"/version","timeoutSeconds":3}}'
LIVE_NO_LEADING_SLASH='{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":"version","timeoutSeconds":3}}'
NO_SHA_PATH='{"postMergeVerify":{"url":"http://127.0.0.1:8731"}}'
DEAD='{"postMergeVerify":{"url":"http://127.0.0.1:8732","timeoutSeconds":3}}'

check 0 'passes when the repo has no config'        none          "$SHA"
check 0 'passes when the config has no verify key'  '{"prefix":"scr"}' "$SHA"
check 0 'passes when the live SHA matches'          "$LIVE"       "$SHA"
check 1 'fails when the live SHA never matches'     "$LIVE"       "2222222222222222222222222222222222222222"
check 0 'joins a shaPath configured without its leading slash' "$LIVE_NO_LEADING_SLASH" "$SHA"
check 0 'checks only the URL without a shaPath'     "$NO_SHA_PATH" "$SHA"
check 1 'fails when the site does not answer'       "$DEAD"       "$SHA"
check 1 'fails on malformed JSON instead of passing as absent' '{not json'   "$SHA"
check 1 'fails on a postMergeVerify block with no url'  '{"postMergeVerify":{}}' "$SHA"
check 0 'passes when pr-standards.json is valid JSON but not an object' '[1, 2, 3]' "$SHA"
check 1 'fails on a postMergeVerify value that is not an object' '{"postMergeVerify":"nope"}' "$SHA"
check 1 'fails on a shaPath that is not a string' '{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":123}}' "$SHA"
check 1 'fails on an empty shaPath instead of silently skipping the poll' '{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":""}}' "$SHA"
check 1 'fails on a shaJsonKey that is not a string' '{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaJsonKey":123}}' "$SHA"
check 1 'fails on a timeoutSeconds that is not a number' '{"postMergeVerify":{"url":"http://127.0.0.1:8731","timeoutSeconds":null}}' "$SHA"

# The failure report is what the issue body quotes. An empty one leaves a
# person with an issue that says nothing.
printf '%s' "$LIVE" > "$WORK/repo/.github/pr-standards.json"
rm -f "$WORK/report.md"
( cd "$WORK/repo" && EXPECTED_SHA=2222222222222222222222222222222222222222 REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
if grep -q 'Expected SHA' "$WORK/report.md" 2>/dev/null; then printf 'ok    %s\n' 'writes a failure report the issue can quote'
else printf 'FAIL  %s\n' 'writes a failure report the issue can quote'; fails=$((fails + 1)); fi

# A transient non-string SHA (e.g. `{"sha": null}` mid-deploy) must keep
# polling to the deadline, not crash out on the first response. A crash and a
# real timeout both exit 1, so tell them apart by whether a report got written
# — only the deadline path calls fail() and writes one.
NULL_SHA='{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":"/version-null","timeoutSeconds":2}}'
printf '%s' "$NULL_SHA" > "$WORK/repo/.github/pr-standards.json"
rm -f "$WORK/report.md"
( cd "$WORK/repo" && EXPECTED_SHA="$SHA" REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
got=$?
if [ "$got" = 1 ] && [ -f "$WORK/report.md" ]; then printf 'ok    %s\n' 'keeps polling instead of crashing on a null SHA'
else printf 'FAIL  %s (want exit 1 with a report, got exit %s)\n' 'keeps polling instead of crashing on a null SHA' "$got"; fails=$((fails + 1)); fi

# A version endpoint answering with valid JSON that isn't an object (e.g. a
# bare array) must not crash the poll loop via AttributeError on `.get()`.
LIST_SHA='{"postMergeVerify":{"url":"http://127.0.0.1:8731","shaPath":"/version-list","timeoutSeconds":2}}'
printf '%s' "$LIST_SHA" > "$WORK/repo/.github/pr-standards.json"
rm -f "$WORK/report.md"
( cd "$WORK/repo" && EXPECTED_SHA="$SHA" REPORT="$WORK/report.md" python3 "$WORK/check.py" ) >/dev/null 2>&1
got=$?
if [ "$got" = 1 ] && [ -f "$WORK/report.md" ]; then printf 'ok    %s\n' 'keeps polling instead of crashing on a non-object response'
else printf 'FAIL  %s (want exit 1 with a report, got exit %s)\n' 'keeps polling instead of crashing on a non-object response' "$got"; fails=$((fails + 1)); fi

[ "$fails" = 0 ] || { printf '\n%s failing\n' "$fails" >&2; exit 1; }
printf '\nall passing\n'
