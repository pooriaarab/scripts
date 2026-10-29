#!/usr/bin/env bash
# End-to-end check of gh-app-read and stack-merge against a fake gh.
# Prints one PASS/FAIL line per case. Exits 1 on any FAIL.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

# Fake gh: logs every call, serves canned answers.
cat > "$tmp/gh" <<'FAKE'
#!/usr/bin/env bash
echo "TOKEN=${GH_TOKEN:-none} $*" >> "$FAKE_LOG"
case "$*" in
  *"--json state"*) echo "${FAKE_STATE:-MERGED}" ;;
  *"--json headRefName"*) echo feature-branch ;;
  *"--json baseRefName"*) echo main ;;
  *"--json headRefOid"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *"issue create"*) echo "https://example.invalid/issues/9" ;;
  *"pulls/"*"/comments?"*) cat "$FAKE_COMMENTS" ;;
esac
FAKE
chmod +x "$tmp/gh"
export FAKE_LOG="$tmp/log" FAKE_COMMENTS="$tmp/comments.json"
: > "$FAKE_LOG"

# gh-app-read: token is mode 600, rotates by pid, reads pass, writes refuse.
export GH_READ_APPS="app-a app-b" GH_APP_TOKEN_CMD='echo "tok-{app}"' GH_READ_CACHE_DIR="$tmp/cache" GH_BIN="$tmp/gh"
mkdir "$tmp/cache"
"$here/gh-app-read" api rate_limit
check "read passes the token" "$(grep -c 'TOKEN=tok-app-' "$FAKE_LOG")" 1
check "token file mode" "$(stat -c %a "$tmp/cache"/* 2>/dev/null || stat -f %Lp "$tmp/cache"/*)" 600
"$here/gh-app-read" pr create >/dev/null 2>&1; check "write refused, exit" "$?" 2
"$here/gh-app-read" api x -f a=b >/dev/null 2>&1; check "api field refused, exit" "$?" 2
check "refused calls never reached gh" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 1

# stack-merge ack: Major stops with exit 2 and writes nothing.
cat > "$FAKE_COMMENTS" <<'JSON'
[{"id":1,"in_reply_to_id":null,"path":"a.ts","line":3,"user":{"login":"bot"},"body":"**Major**: this fails open on NaN."},
 {"id":2,"in_reply_to_id":null,"path":"b.ts","line":9,"user":{"login":"bot"},"body":"Minor: rename this."},
 {"id":3,"in_reply_to_id":2,"path":"b.ts","line":9,"user":{"login":"me"},"body":"done"}]
JSON
export STACK_READ_GH="$tmp/gh" STACK_WRITE_GH="$tmp/gh"
: > "$FAKE_LOG"
"$here/stack-merge" ack o/r 5 >/dev/null 2>&1; check "ack stops on Major, exit" "$?" 2
check "ack wrote nothing" "$(grep -c -E 'issue create|replies' "$FAKE_LOG")" 0

# Minor only: files one issue and replies once.
cat > "$FAKE_COMMENTS" <<'JSON'
[{"id":2,"in_reply_to_id":null,"path":"b.ts","line":9,"user":{"login":"bot"},"body":"Minor: rename this."}]
JSON
: > "$FAKE_LOG"
out=$("$here/stack-merge" ack o/r 5); check "ack minor, exit" "$?" 0
check "ack minor summary" "$out" "#5: replied to 1 comment(s), tracking issue #9"
check "ack one reply" "$(grep -c 'replies' "$FAKE_LOG")" 1

# prep: refuses an unmerged PR, deletes only after retarget.
: > "$FAKE_LOG"; FAKE_STATE=OPEN "$here/stack-merge" prep o/r 4 5 >/dev/null 2>&1; check "prep refuses unmerged, exit" "$?" 2
check "prep touched nothing" "$(grep -c -E 'pr edit|DELETE' "$FAKE_LOG")" 0
: > "$FAKE_LOG"; "$here/stack-merge" prep o/r 4 5 >/dev/null
check "retarget before delete" "$(grep -n -E 'pr edit|DELETE' "$FAKE_LOG" | cut -d: -f1 | tr '\n' ' ')" "3 5 "

# gate: PASS prints the full-SHA merge command and never merges.
: > "$FAKE_LOG"
out=$(STACK_GATE_CMD='true' "$here/stack-merge" gate o/r 5)
check "gate prints merge command" "$(grep -c 'gh pr merge 5 -R o/r --merge --match-head-commit 0123456789abcdef0123456789abcdef01234567' <<<"$out")" 1
check "gate never merged" "$(grep -c 'pr merge' "$FAKE_LOG")" 0
STACK_GATE_CMD='exit 3' "$here/stack-merge" gate o/r 5 >/dev/null; check "gate HOLD, exit" "$?" 2
exit $fail
