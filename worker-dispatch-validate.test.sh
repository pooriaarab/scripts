#!/usr/bin/env bash
# Tests for worker-dispatch-validate and its box-work gate. Offline: stub gh,
# fixture git checkouts, synthetic manifests. No Box, branch, or worker
# command is ever invoked by the validator; a sentinel file stands in for that
# mutation, and a `box` stub fails the run if the validator ever calls it.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${WORKER_DISPATCH_UNDER_TEST:-$DIR/worker-dispatch-validate}"
BOXWORK="${BOX_WORK_UNDER_TEST:-$DIR/box-work}"
PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/xdg" "$T/fakehome"
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
    state="$(cat "$T/issue-state")"; [ "$jqexpr" = .state ] && printf '%s\n' "$state" || printf '{"state":"%s"}\n' "$state" ;;
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
# box-work valid-path stub: records calls, serves new + ready probe.
cat > "$T/bin/box-ok" <<'STUB'
#!/usr/bin/env bash
echo "box-ok $*" >>"${DISPATCH_TEST_T:?}/boxcalls.log"
case "${1:-}" in
  new) printf '{"id":"bx_validpath001"}\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/box-ok"
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
    elif k == "issue": m[k]=int(v)
    elif k == "resume": m[k]=(v=="true")
    else: m[k]=v
json.dump(m, open(out,"w"))
PY
}

reset() { rm -f "$T"/state/*.json "$T"/state/.receipt-*.tmp "$T/sentinel" "$T/box-called" "$T/gh.log" "$T/boxcalls.log"; rm -rf "$T"/state/*.lock; : > "$T/gh.log"; rm -f "$T/no-config"; printf 'none' > "$T/apifail"; printf 'open' > "$T/issue-state"; }

# The sentinel stands in for the Box/branch/worker mutation: it runs only
# when validation passes, so its absence proves rejection came first.
attempt() { # <manifest> [extra validator args...]
  local m="$1"; shift
  out="$("$SCRIPT" --manifest "$m" "$@" 2>&1)"; rc=$?
  (( rc == 0 )) && touch "$T/sentinel"
}

reset; mkmanifest "$T/valid.json"
attempt "$T/valid.json" --checkout "$T/checkout"
BLOB="$(git -C "$T/checkout" rev-parse HEAD:.github/pr-standards.json)"
checkout_ok=0
(( rc == 0 )) && [ -f "$T/sentinel" ] \
  && grep -q "\"base_sha\": \"$(cat "$T/live-sha")\"" "$T"/state/*.json \
  && grep -q "\"config_sha\": \"$BLOB\"" "$T"/state/*.json \
  && ! grep -q "local-checkout" "$T"/state/*.json && checkout_ok=1
rm -f "$T/sentinel"
mkmanifest "$T/valid-api.json" resume="true"
attempt "$T/valid-api.json"
api_ok=0
(( rc == 0 )) && [ -f "$T/sentinel" ] \
  && grep -q '"config_sha": "cfgsha-test"' "$T"/state/*.json && api_ok=1
if (( checkout_ok == 1 && api_ok == 1 )); then pass "valid manifest passes, reaches the sentinel, records pinned config/base SHAs"; else fail "valid manifest passes, reaches the sentinel, records pinned config/base SHAs" "rc=$rc out=$out checkout_ok=$checkout_ok api_ok=$api_ok"; fi
# One runner for every single-shot and ownership case:
# name|setup|overrides (; separated)|mode|want (fail|pass)|grep.
# setup: closed | noconfig | apifail=X | seed-owned | keep | drift | empty.
# mode: checkout | api. Ownership rows reuse the seeded record (keep).
run_case() {
  local name setup overrides mode want grepwant
  IFS='|' read -r name setup overrides mode want grepwant <<< "$1"
  if [ "$setup" != keep ]; then reset; fi
  case "$setup" in
    closed) printf 'closed' > "$T/issue-state" ;;
    noconfig) touch "$T/no-config" ;;
    apifail=*) printf '%s' "${setup#apifail=}" > "$T/apifail" ;;
    seed-owned) mkmanifest "$T/owned.json"; attempt "$T/owned.json" --checkout "$T/checkout" ;;
    drift)
      first="$(cat "$T/live-sha")"
      git -C "$T/checkout" rev-parse HEAD > "$T/orig-sha"
      echo more > "$T/checkout/file.txt"
      git -C "$T/checkout" commit -qam second
      printf '%s' "$first" > "$T/live-sha" ;;
  esac
  rm -f "$T/sentinel"
  local args=() o OV
  IFS=';' read -ra OV <<< "$overrides"
  for o in "${OV[@]}"; do [ -n "$o" ] && args+=("$o"); done
  if ((${#args[@]})); then mkmanifest "$T/case.json" "${args[@]}"; else mkmanifest "$T/case.json"; fi
  if [ "$mode" = checkout ]; then attempt "$T/case.json" --checkout "$T/checkout"; else attempt "$T/case.json"; fi
  local good=0
  if [ "$want" = pass ]; then
    (( rc == 0 )) && [ -f "$T/sentinel" ] && good=1
  elif (( rc != 0 )) && [ ! -f "$T/sentinel" ] && { [ -z "$grepwant" ] || echo "$out" | grep -q "$grepwant"; }; then
    good=1
  fi
  if (( good == 1 )); then pass "$name"; else fail "$name" "rc=$rc out=$out"; fi
}
while IFS= read -r row; do [ -n "$row" ] && run_case "$row"; done <<'CASES'
wrong prefix branch fails before the sentinel||branch=pc-976-fix-the-widget;title=[PC-976] Fix the widget output|checkout|fail|
closed issue fails before the sentinel|closed||checkout|fail|not open
title bound to another issue fails before the sentinel||title=[POP-977] Fix the widget output|checkout|fail|
two closing references fail before the sentinel||closing_ref=Closes #976 and Fixes #977|checkout|fail|
stale base_sha fails before the sentinel||base_sha=0000000000000000000000000000000000000000|checkout|fail|differ
short base_sha is rejected||base_sha=abcdef12|checkout|fail|base_sha
long base_sha is rejected||base_sha=abcdef0123456789abcdef0123456789abcdef012|checkout|fail|base_sha
uppercase base_sha is rejected||base_sha=ABCDEF0123456789ABCDEF0123456789ABCDEF01|checkout|fail|base_sha
missing field fails before the sentinel||model=@DROP@|checkout|fail|missing required
missing repository configuration fails before the sentinel|noconfig||api|fail|configuration
API failure fails before the sentinel with no fallback|apifail=all||api|fail|
conflicting ownership is rejected|seed-owned|coordinator=coord-b;branch=pop-976-other-attempt;box=bx_other999|checkout|fail|conflict
explicit matching resume passes|keep|resume=true|checkout|pass|
resume with a conflicting Box identity is rejected|keep|resume=true;box=bx_someone_else|checkout|fail|mismatch on: box
resume with a conflicting branch is rejected|keep|resume=true;branch=pop-976-someone-elses-work|checkout|fail|branch
checkout drift from the declared base fails before the sentinel|drift||checkout|fail|checkout HEAD
CASES
git -C "$T/checkout" reset -q --hard "$(cat "$T/orig-sha")"
git -C "$T/checkout" rev-parse HEAD | tr -d '\n' > "$T/live-sha"
# bw <manifest> <log> [extra box-work args...]; echoes box-work's rc.
bw() {
  local m="$1" log="$2"; shift 2
  BOX_CLI="$T/bin/box" GH_CLI="$T/bin/gh" "$BOXWORK" "$T/checkout" --manifest "$m" "$@" >"$log" 2>&1; echo $?
}
# box-work gate: an invalid manifest stops before ANY Box call.
reset; mkmanifest "$T/gate-bad.json" branch="pc-976-fix-the-widget" title="[PC-976] Fix the widget output"
grc="$(bw "$T/gate-bad.json" "$T/gate.log" --agent pi "do work")"
(( grc != 0 )) && [ ! -f "$T/box-called" ] && pass "box-work with an invalid manifest makes no Box call" || fail "box-work with an invalid manifest makes no Box call" "rc=$grc log=$(cat "$T/gate.log")"
# CLI mismatch (and empty --agent): rejected before any receipt, Box, start, sync, or worker effect.
reset; mkmanifest "$T/gate-mismatch.json"
mrc="$(bw "$T/gate-mismatch.json" "$T/mismatch.log" --agent pi "do work")"
mrc2="$(bw "$T/gate-mismatch.json" "$T/empty-agent.log" --agent "" "do work")"
if (( mrc != 0 )) && (( mrc2 != 0 )) && [ ! -f "$T/box-called" ] && [ -z "$(ls "$T"/state/*.json 2>/dev/null)" ] \
  && grep -q "does not match" "$T/mismatch.log" && grep -q "needs a CLI name" "$T/empty-agent.log"; then pass "box-work cli mismatch writes no receipt and makes no Box call"; else fail "box-work cli mismatch writes no receipt and makes no Box call" "rc=$mrc/$mrc2 log=$(cat "$T/mismatch.log")"; fi
# Valid manifest through box-work: exactly one Box start and one receipt.
reset; mkmanifest "$T/gate-ok.json"
okrc="$(HOME="$T/fakehome" BOX_CLI="$T/bin/box-ok" GH_CLI="$T/bin/gh" "$BOXWORK" "$T/checkout" --manifest "$T/gate-ok.json" >"$T/ok.log" 2>&1; echo $?)"
starts="$(grep -c "^box-ok new" "$T/boxcalls.log" 2>/dev/null)"; starts="${starts:-0}"
if (( okrc == 0 )) && [ "$starts" = 1 ] && [ -n "$(ls "$T"/state/*.json 2>/dev/null)" ]; then pass "box-work with a valid manifest starts exactly one Box and records one receipt"; else fail "box-work with a valid manifest starts exactly one Box and records one receipt" "rc=$okrc starts=$starts log=$(cat "$T/ok.log")"; fi
# Concurrent dispatch: exactly one winner, one receipt, winner preserved.
reset
for i in 1 2 3 4 5 6 7 8; do
  mkmanifest "$T/race-$i.json" coordinator="coord-race-$i" branch="pop-976-race-attempt-$i" box="bx_race_$i"
  ("$SCRIPT" --manifest "$T/race-$i.json" --checkout "$T/checkout" >"$T/race-out-$i" 2>&1; echo "$?" >"$T/race-rc-$i") &
done
wait
wins="$(grep -l '^0$' "$T"/race-rc-* 2>/dev/null | wc -l)"
nreceipts="$(ls "$T"/state/*.json 2>/dev/null | wc -l)"
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
exit "$((FAIL > 0))"
