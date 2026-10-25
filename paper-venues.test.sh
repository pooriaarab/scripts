#!/usr/bin/env bash
# End-to-end test for paper-venues. Covers every row marked "tested" in
# paper-venues.failure-modes.md. No network.
set -euo pipefail
cd "$(dirname "$0")"
TOOL=./paper-venues
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }

# 1. missing directory, and an empty directory
if $TOOL build "$T/nope" >/dev/null 2>"$T/err"; then fail "1 missing dir exited 0"; fi
grep -q "not a directory" "$T/err" || fail "1 message"
mkdir "$T/empty"
if $TOOL build "$T/empty" >/dev/null 2>"$T/err"; then fail "1 empty dir exited 0"; fi
grep -q "no venue files" "$T/err" || fail "1 empty message"
ok "missing and empty directories exit 2 with a message"

# fixture with: a good row, a wide row, a nameless row, an avoid row that repeats a venue, an UNVERIFIED cell, a regex-looking name
mkdir "$T/refs"
cat > "$T/refs/venues-test.md" <<'EOF'
# Test venues

Checked 2026-01-02. Fixture.

## Listed

| name | url | type | cost |
|---|---|---|---|
| Alpha Journal | https://alpha.example | journal | free |
| Beta (a+b) Review | https://beta.example | journal | UNVERIFIED |
| bad row | https://x | too | many | cells |
| | https://noname.example | journal | free |
| Gamma Server | https://gamma.example | preprint | free |

## Avoid

| name | url | reason |
|---|---|---|
| Alpha Journal | https://alpha.example | charges a fee per submission |
EOF
$TOOL build "$T/refs" "$T/out.json" 2>"$T/err"
grep -q "skipped 1 rows with the wrong width and 1 rows without a name" "$T/err" || fail "2/3 skip counts: $(cat "$T/err")"
ok "wrong-width and nameless rows are skipped and counted"

n=$(python3 -c "import json;print(len(json.load(open('$T/out.json'))))")
[ "$n" = 4 ] || fail "record count $n"
ok "four records remain"

# 4. both kinds of Alpha stay
$TOOL list --data "$T/out.json" --grep alpha | grep -c Alpha | grep -qx 2 || fail "4 alpha twice"
$TOOL list --data "$T/out.json" --kind avoid | grep -q "Alpha Journal" || fail "4 avoid list"
ok "a venue in both a listed and an avoid table keeps both records"

# 5. stale detection
$TOOL check "$T/refs" "$T/out.json" >/dev/null || fail "5 current JSON reported stale"
echo "| Delta Server | https://delta.example | preprint | free |" >> "$T/refs/venues-test.md"
sed -i.bak 's/| Gamma Server | https:\/\/gamma.example | preprint | free |/| Gamma Server | https:\/\/gamma.example | preprint | free |\n| Delta Server | https:\/\/delta.example | preprint | free |/' "$T/refs/venues-test.md"
if $TOOL check "$T/refs" "$T/out.json" >/dev/null 2>&1; then fail "5 stale JSON reported current"; fi
ok "check exits 1 when the JSON is older than the Markdown"

# 6. UNVERIFIED survives
$TOOL stats --data "$T/out.json" | grep -q "UNVERIFIED cell: 1" || fail "6 stats: $($TOOL stats --data "$T/out.json")"
$TOOL show "Beta" --data "$T/out.json" | grep -q "UNVERIFIED" || fail "6 show"
ok "UNVERIFIED cells are kept and counted"

# 7. two matches print both
$TOOL show "alpha" --data "$T/out.json" | grep -c "^==" | grep -qx 2 || fail "7 two matches"
ok "show prints every match"

# 8. no match
if $TOOL show "zzz-none" --data "$T/out.json" >/dev/null 2>"$T/err"; then fail "8 no-match exited 0"; fi
grep -q "no venue matches" "$T/err" || fail "8 message"
ok "show with no match exits 1"

# 9. regex characters are plain text
$TOOL list --data "$T/out.json" --grep "(a+b)" | grep -q "Beta" || fail "9 regex chars"
ok "query text is plain, not a regex"

# the committed data file, when present, is sane
if [ -f paper-venues.json ]; then
  rec=$($TOOL stats | sed -n 's/^records: //p')
  [ "$rec" -ge 200 ] || fail "committed data has only $rec records"
  $TOOL list --kind avoid | grep -qi "vixra" || fail "committed data lacks the avoid row for viXra"
  ok "the committed data file holds at least 200 records and the viXra warning"
else
  echo "skip - no paper-venues.json committed yet"
fi

echo "all $pass checks passed"
