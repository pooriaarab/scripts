#!/usr/bin/env bash
# Tests for worker-dispatch-validate. Offline: stub gh, fixture git checkouts,
# synthetic manifests. No Box, branch, or worker command is ever invoked by
# the validator; a sentinel file stands in for that mutation, and a `box`
# stub fails the run if the validator ever calls it.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${WORKER_DISPATCH_UNDER_TEST:-$DIR/worker-dispatch-validate}"
PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/xdg"
export WORKER_DISPATCH_STATE="$T/state" DISPATCH_TEST_T="$T"
export XDG_STATE_HOME="$T/xdg"

cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T="${DISPATCH_TEST_T:?}"
echo "gh $*" >>"$T/gh.log"
[ "${1:-}" = "api" ] || { echo "stub gh: want api" >&2; exit 9; }
shift
endpoint="$1"; shift
jqexpr=""
while [ $# -gt 0 ]; do case "$1" in --jq) jqexpr="$2"; shift 2;; *) shift;; esac; done
failmode="$(cat "$T/apifail" 2>/dev/null || echo none)"
case "$endpoint" in
  repos/*/contents/.github/pr-standards.json\?ref=*)
    case "$failmode" in config|all) echo "API 500 exploded" >&2; exit 1;; esac
    [ -f "$T/no-config" ] && { echo "404 not found" >&2; exit 1; }
    prefix="$(cat "$T/config-prefix")"
    content="$(printf '{"prefix":"%s"}' "$prefix" | base64 | tr -d '\n')"
    printf '{"sha":"cfgsha-test","content":"%s"}\n' "$content" ;;
  repos/*/issues/*)
    case "$failmode" in issue|all) echo "API 500 exploded" >&2; exit 1;; esac
    state="$(cat "$T/issue-state")"; extra=""; [ -f "$T/issue-is-pr" ] && extra=',"pull_request":{"url":"x"}'
    printf '{"state":"%s"%s}\n' "$state" "$extra" ;;
  repos/*/commits/*)
    case "$failmode" in base|all) echo "API 500 exploded" >&2; exit 1;; esac
    sha="$(cat "$T/live-sha")"; [ "$jqexpr" = .sha ] && printf '%s\n' "$sha" || printf '{"sha":"%s"}\n' "$sha" ;;
  *) echo "stub gh: unknown endpoint $endpoint" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/gh"
# Any Box call from the validator is a bug: record it and fail loudly.
cat > "$T/bin/box" <<'STUB'
#!/usr/bin/env bash
echo "box $*" >>"${DISPATCH_TEST_T:?}/boxcalls.log"
touch "${DISPATCH_TEST_T:?}/box-called"
exit 99
STUB
chmod +x "$T/bin/box"
PATH="$T/bin:$PATH"
# Fixture checkout: origin matches the manifest repo, HEAD is the live base.
git init -q "$T/checkout"
git -C "$T/checkout" config user.email test@example.com
git -C "$T/checkout" config user.name test
git -C "$T/checkout" config commit.gpgsign false
git -C "$T/checkout" remote add origin https://github.com/pooriaarab/popcornteam.git
echo base > "$T/checkout/file.txt"
mkdir -p "$T/checkout/.github"
printf '{"prefix":"pop"}' > "$T/checkout/.github/pr-standards.json"
git -C "$T/checkout" add file.txt .github/pr-standards.json
git -C "$T/checkout" commit -qm base
git -C "$T/checkout" rev-parse HEAD | tr -d '\n' > "$T/live-sha"
printf 'open' > "$T/issue-state"
printf 'pop' > "$T/config-prefix"
printf 'none' > "$T/apifail"

# mkmanifest <out> [KEY=VALUE ...]; VALUE=@DROP@ removes the key.
mkmanifest() {
  python3 - "$1" "$T/live-sha" "${@:2}" <<'PY'
import json,sys
out, shafile, over = sys.argv[1], sys.argv[2], sys.argv[3:]
sha = open(shafile).read().strip()
m = {"repository":"pooriaarab/popcornteam","issue":976,"branch":"pop-976-fix-the-widget",
 "title":"[POP-976] Fix the widget output","closing_ref":"Closes #976","base_ref":"main",
 "base_sha":sha,"coordinator":"coord-a","cli":"muse","model":"muse-spark-1.3-contributor","box":"bx_resume123"}
for o in over:
    k, v = o.split("=",1)
    if v == "@DROP@": m.pop(k,None)
    elif v.startswith("@JSON:"): m[k]=json.loads(v[len("@JSON:"):])
    elif v.startswith("@STR:"): m[k]=v[len("@STR:"):]
    elif k == "issue": m[k]=int(v)
    elif k == "resume": m[k]=(v=="true")
    else: m[k]=v
json.dump(m, open(out,"w"))
PY
}

reset() { rm -f "$T"/state/*.json "$T"/state/.receipt-*.tmp "$T/sentinel" "$T/box-called" "$T/gh.log" "$T/boxcalls.log"; rm -rf "$T"/state/*.lock; : > "$T/gh.log"; rm -f "$T/no-config" "$T/issue-is-pr"; printf 'none' > "$T/apifail"; printf 'open' > "$T/issue-state"; printf 'pop' > "$T/config-prefix"; }

# The sentinel stands in for Box/branch/worker mutation: its absence proves rejection came first.
attempt() { # <manifest> [extra validator args...]
  local m="$1"; shift
  out="$("$SCRIPT" --manifest "$m" "$@" 2>&1)"; rc=$?
  (( rc == 0 )) && touch "$T/sentinel"
}

# Valid checkout manifest: passes, reaches the sentinel, records pinned SHAs.
reset; mkmanifest "$T/valid.json"; attempt "$T/valid.json" --checkout "$T/checkout"
BLOB="$(git -C "$T/checkout" rev-parse HEAD:.github/pr-standards.json)"
if (( rc == 0 )) && [ -f "$T/sentinel" ] && grep -q "\"base_sha\": \"$(cat "$T/live-sha")\"" "$T"/state/*.json \
  && grep -q "\"config_sha\": \"$BLOB\"" "$T"/state/*.json && ! grep -q "local-checkout" "$T"/state/*.json; then
  pass "valid manifest passes, reaches the sentinel, records pinned config/base SHAs"
else
  fail "valid manifest passes, reaches the sentinel, records pinned config/base SHAs" "rc=$rc out=$out"
fi
# One runner for every single-shot and ownership case:
# name|setup|overrides (; separated)|mode|want|grep|extra validator args.
# setup: closed | ispr | noconfig | apifail=X | prefix=X | seed-owned | keep | drift | empty.
# mode: checkout | api. want: pass (grep scans the receipt) | fail | failclean (fail, no receipt).
# Ownership rows reuse the seeded record (keep).
run_case() {
  local name setup overrides mode want grepwant extra
  IFS='|' read -r name setup overrides mode want grepwant extra <<< "$1"
  if [ "$setup" != keep ]; then reset; fi
  case "$setup" in
    closed) printf 'closed' > "$T/issue-state" ;;
    ispr) touch "$T/issue-is-pr" ;;
    noconfig) touch "$T/no-config" ;;
    apifail=*) printf '%s' "${setup#apifail=}" > "$T/apifail" ;;
    prefix=*) printf '%s' "${setup#prefix=}" > "$T/config-prefix" ;;
    seed-owned) mkmanifest "$T/owned.json"; attempt "$T/owned.json" --checkout "$T/checkout" ;;
    drift)
      git -C "$T/checkout" rev-parse HEAD > "$T/orig-sha"
      echo more > "$T/checkout/file.txt"; git -C "$T/checkout" commit -qam second
      printf '%s' "$(cat "$T/orig-sha")" > "$T/live-sha" ;;
  esac
  rm -f "$T/sentinel"
  local args=() o OV
  IFS=';' read -ra OV <<< "$overrides"
  for o in "${OV[@]}"; do [ -n "$o" ] && args+=("$o"); done
  if ((${#args[@]})); then mkmanifest "$T/case.json" "${args[@]}"; else mkmanifest "$T/case.json"; fi
  # shellcheck disable=SC2086
  if [ "$mode" = checkout ]; then attempt "$T/case.json" --checkout "$T/checkout" $extra; else attempt "$T/case.json" $extra; fi
  local good=0
  if [ "$want" = pass ]; then
    (( rc == 0 )) && [ -f "$T/sentinel" ] && { [ -z "$grepwant" ] || grep -rq "$grepwant" "$T/state"; } && good=1
  elif [ "$want" = failclean ]; then
    (( rc != 0 )) && [ ! -f "$T/sentinel" ] && [ -z "$(ls "$T"/state/*.json 2>/dev/null)" ] \
      && { [ -z "$grepwant" ] || echo "$out" | grep -q "$grepwant"; } && good=1
  elif (( rc != 0 )) && [ ! -f "$T/sentinel" ] && { [ -z "$grepwant" ] || echo "$out" | grep -q "$grepwant"; }; then
    good=1
  fi
  if (( good == 1 )); then pass "$name"; else fail "$name" "rc=$rc out=$out"; fi
}
while IFS= read -r row; do [ -n "$row" ] && run_case "$row"; done <<'CASES'
valid api manifest passes and records the API config SHA|||api|pass|cfgsha-test|
wrong prefix branch fails before the sentinel||branch=pc-976-fix-the-widget;title=[PC-976] Fix the widget output|checkout|fail|
leading-zero issue string is rejected before any use||issue=@STR:0976|checkout|fail|canonical|
zero issue number is rejected||issue=@JSON:0|checkout|fail|positive|
closed issue fails before the sentinel|closed||checkout|fail|not open
open pull request is not the required issue|ispr||checkout|fail|pull request|
title bound to another issue fails before the sentinel||title=[POP-977] Fix the widget output|checkout|fail|
Fixes reference does not satisfy the closing requirement||closing_ref=Fixes #976|checkout|fail|closing_ref|
Resolves reference does not satisfy the closing requirement||closing_ref=Resolves #976|checkout|fail|closing_ref|
lowercase closes reference is accepted||closing_ref=closes #976|checkout|pass||
colon Closes reference is accepted||closing_ref=Closes: #976|checkout|pass||
two closing references fail before the sentinel||closing_ref=Closes #976 and Fixes #977|checkout|fail|
two Closes references fail before the sentinel||closing_ref=Closes #976 and Closes #977|checkout|fail|
Closes reference to another issue fails||closing_ref=Closes #977|checkout|fail|closing_ref|
stale base_sha fails before the sentinel||base_sha=0000000000000000000000000000000000000000|checkout|fail|differ
short base_sha is rejected||base_sha=abcdef12|checkout|fail|base_sha
long base_sha is rejected||base_sha=abcdef0123456789abcdef0123456789abcdef012|checkout|fail|base_sha
uppercase base_sha is rejected||base_sha=ABCDEF0123456789ABCDEF0123456789ABCDEF01|checkout|fail|base_sha
missing field fails before the sentinel||model=@DROP@|checkout|fail|missing required
non-string box object is rejected||box=@JSON:{"id":"bx_resume123"}|checkout|fail|must be strings
non-string model list is rejected||model=@JSON:["muse-spark-1.3-contributor"]|checkout|fail|must be strings
numeric repository is rejected||repository=@JSON:123|checkout|fail|must be strings
boolean issue is rejected||issue=@JSON:true|checkout|fail|issue number
non-boolean resume is rejected||resume=@JSON:"true"|checkout|fail|must be a boolean
missing repository configuration fails before the sentinel|noconfig||api|fail|configuration
present but invalid prefix fails before the sentinel|prefix=POP123||api|fail|invalid prefix
API failure fails before the sentinel with no fallback|apifail=all||api|fail|
conflicting ownership is rejected|seed-owned|coordinator=coord-b;branch=pop-976-other-attempt;box=bx_other999|checkout|fail|conflict
canonical string issue shares ownership with int issue|seed-owned|coordinator=coord-b;branch=pop-976-other-attempt;box=bx_other999;issue=@STR:976|checkout|fail|conflict
explicit matching resume passes|keep|resume=true|checkout|pass|
agent mismatch writes no receipt|||checkout|failclean|does not match|--agent pi
matching agent passes and records a receipt|||checkout|pass|"cli": "muse"|--agent muse
resume with a conflicting Box identity is rejected|keep|resume=true;box=bx_someone_else|checkout|fail|mismatch on: box
resume with a conflicting branch is rejected|keep|resume=true;branch=pop-976-someone-elses-work|checkout|fail|branch
checkout drift from the declared base fails before the sentinel|drift||checkout|fail|checkout HEAD
CASES
git -C "$T/checkout" reset -q --hard "$(cat "$T/orig-sha")"; git -C "$T/checkout" rev-parse HEAD | tr -d '\n' > "$T/live-sha"
# Sequential canonical equivalence: int 976 then string "976" share one receipt.
reset; mkmanifest "$T/seq.json"; attempt "$T/seq.json" --checkout "$T/checkout"
mkmanifest "$T/seq-str.json" issue=@STR:976 coordinator=coord-b branch=pop-976-other-attempt box=bx_other999
attempt "$T/seq-str.json" --checkout "$T/checkout"; nrc="$(ls "$T"/state/*.json 2>/dev/null | wc -l)"
if (( rc != 0 )) && [ "$nrc" = 1 ] && echo "$out" | grep -q conflict; then
  pass "canonical-equivalent sequential attempt shares one receipt"
else
  fail "canonical-equivalent sequential attempt shares one receipt" "rc=$rc receipts=$nrc out=$out"
fi
# Concurrent dispatch: exactly one winner, one receipt, winner preserved.
reset
for i in 1 2 3 4 5 6 7 8; do
  # Alternate int/string issue forms: canonical-equivalent racers share one receipt.
  (( i % 2 == 0 )) && iform="issue=@STR:976" || iform="issue=976"
  mkmanifest "$T/race-$i.json" coordinator="coord-race-$i" branch="pop-976-race-attempt-$i" box="bx_race_$i" "$iform"
  ("$SCRIPT" --manifest "$T/race-$i.json" --checkout "$T/checkout" >"$T/race-out-$i" 2>&1; echo "$?" >"$T/race-rc-$i") &
done
wait
wins="$(grep -l '^0$' "$T"/race-rc-* 2>/dev/null | wc -l)"; nreceipts="$(ls "$T"/state/*.json 2>/dev/null | wc -l)"
wcoord="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("coordinator",""))' "$T"/state/*.json 2>/dev/null)"
case "$wcoord" in coord-race-[1-8]) wok=1 ;; *) wok=0 ;; esac
losers_ok=1
winner="${wcoord#coord-race-}"
for f in "$T"/race-out-*; do
  case "$f" in *"-$winner") continue ;; esac
  grep -qi "conflict\|active dispatch\|resume" "$f" || losers_ok=0
done
if [ "$wins" = 1 ] && [ "$nreceipts" = 1 ] && (( wok == 1 && losers_ok == 1 )); then
  touch "$T/sentinel"
  pass "concurrent dispatch claims exactly one receipt for exactly one winner"
else
  fail "concurrent dispatch claims exactly one receipt for exactly one winner" "wins=$wins receipts=$nreceipts coord=$wcoord"
fi
rm -f "$T/sentinel"
[ ! -f "$T/box-called" ] && pass "validator never invokes the Box CLI" || fail "validator never invokes the Box CLI" "box was called"
echo "---"
echo "$PASS passed, $FAIL failed"
if (( FAIL > 0 )); then exit 1; else exit 0; fi
