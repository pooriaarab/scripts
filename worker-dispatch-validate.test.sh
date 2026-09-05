#!/usr/bin/env bash
# Tests for worker-dispatch-validate and its box-work gate. Offline: stub gh,
# fixture git checkouts, synthetic manifests. No Box, branch, or worker
# command is ever invoked; a sentinel file stands in for that mutation, and a
# `box` stub fails the run if the validator ever calls it.
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
  repos/*/contents/.github/pr-standards.json)
    case "$failmode" in config|all) echo "API 500 exploded" >&2; exit 1;; esac
    [ -f "$T/no-config" ] && { echo "404 not found" >&2; exit 1; }
    prefix="$(cat "$T/config-prefix")"
    content="$(printf '{"prefix":"%s"}' "$prefix" | base64 | tr -d '\n')"
    printf '{"sha":"cfgsha-test","content":"%s"}\n' "$content" ;;
  repos/*/issues/*)
    case "$failmode" in issue|all) echo "API 500 exploded" >&2; exit 1;; esac
    state="$(cat "$T/issue-state")"
    case "$jqexpr" in ".state") printf '%s\n' "$state";; *) printf '{"state":"%s"}\n' "$state";; esac ;;
  repos/*/commits/*)
    case "$failmode" in base|all) echo "API 500 exploded" >&2; exit 1;; esac
    sha="$(cat "$T/live-sha")"
    case "$jqexpr" in ".sha") printf '%s\n' "$sha";; *) printf '{"sha":"%s"}\n' "$sha";; esac ;;
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
     "title":"[POP-976] Fix the widget output","closing_ref":"Closes #976",
     "base_ref":"main","base_sha":sha,"coordinator":"coord-a",
     "cli":"muse","model":"muse-spark-1.3-contributor","box":"bx_resume123"}
for o in over:
    k, v = o.split("=",1)
    if v == "@DROP@": m.pop(k,None)
    elif k == "issue": m[k]=int(v)
    elif k == "resume": m[k]=(v=="true")
    else: m[k]=v
json.dump(m, open(out,"w"))
PY
}

reset() { rm -f "$T"/state/*.json "$T/sentinel" "$T/box-called" "$T/gh.log"; : > "$T/gh.log"; rm -f "$T/no-config"; printf 'none' > "$T/apifail"; printf 'open' > "$T/issue-state"; }

# The sentinel stands in for the Box/branch/worker mutation: it runs only
# when validation passes, so its absence proves rejection came first.
attempt() { # <manifest> [extra validator args...]
  local m="$1"; shift
  out="$("$SCRIPT" --manifest "$m" "$@" 2>&1)"; rc=$?
  (( rc == 0 )) && touch "$T/sentinel"
}

reset; mkmanifest "$T/valid.json"
attempt "$T/valid.json" --checkout "$T/checkout"
checkout_ok=0
(( rc == 0 )) && [ -f "$T/sentinel" ] \
  && grep -q "\"base_sha\": \"$(cat "$T/live-sha")\"" "$T"/state/*.json && checkout_ok=1
rm -f "$T/sentinel"
mkmanifest "$T/valid-api.json" resume="true"
attempt "$T/valid-api.json"
api_ok=0
(( rc == 0 )) && [ -f "$T/sentinel" ] \
  && grep -q '"config_sha": "cfgsha-test"' "$T"/state/*.json && api_ok=1
if (( checkout_ok == 1 && api_ok == 1 )); then
  pass "valid manifest passes, reaches the sentinel, records config/base SHAs"
else
  fail "valid manifest passes, reaches the sentinel, records config/base SHAs" "rc=$rc out=$out checkout_ok=$checkout_ok api_ok=$api_ok"
fi

reset; mkmanifest "$T/badprefix.json" branch="pc-976-fix-the-widget" title="[PC-976] Fix the widget output"
attempt "$T/badprefix.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ]; then
  pass "wrong prefix branch fails before the sentinel"
else
  fail "wrong prefix branch fails before the sentinel" "rc=$rc out=$out"
fi

reset; printf 'closed' > "$T/issue-state"; mkmanifest "$T/closed.json"
attempt "$T/closed.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -q "not open"; then
  pass "closed issue fails before the sentinel"
else
  fail "closed issue fails before the sentinel" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/badtitle.json" title="[POP-977] Fix the widget output"
attempt "$T/badtitle.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ]; then
  pass "title bound to another issue fails before the sentinel"
else
  fail "title bound to another issue fails before the sentinel" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/twoclose.json" closing_ref="Closes #976 and Fixes #977"
attempt "$T/twoclose.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ]; then
  pass "two closing references fail before the sentinel"
else
  fail "two closing references fail before the sentinel" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/stale.json" base_sha="0000000000000000000000000000000000000000"
attempt "$T/stale.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -qi "differ"; then
  pass "stale base_sha fails before the sentinel"
else
  fail "stale base_sha fails before the sentinel" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/missing.json" model="@DROP@"
attempt "$T/missing.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -q "missing required"; then
  pass "missing field fails before the sentinel"
else
  fail "missing field fails before the sentinel" "rc=$rc out=$out"
fi

reset; touch "$T/no-config"; mkmanifest "$T/noconfig.json"
attempt "$T/noconfig.json"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -qi "configuration"; then
  pass "missing repository configuration fails before the sentinel"
else
  fail "missing repository configuration fails before the sentinel" "rc=$rc out=$out"
fi
rm -f "$T/no-config"

reset; printf 'all' > "$T/apifail"; mkmanifest "$T/apifail.json"
attempt "$T/apifail.json"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ]; then
  pass "API failure fails before the sentinel with no fallback"
else
  fail "API failure fails before the sentinel with no fallback" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/first.json"; attempt "$T/first.json" --checkout "$T/checkout"
rm -f "$T/sentinel"
mkmanifest "$T/rival.json" coordinator="coord-b" branch="pop-976-other-attempt" box="bx_other999"
attempt "$T/rival.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -qi "conflict"; then
  pass "conflicting ownership is rejected"
else
  fail "conflicting ownership is rejected" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/owned.json"; attempt "$T/owned.json" --checkout "$T/checkout"
rm -f "$T/sentinel"
mkmanifest "$T/resume.json" resume="true"
attempt "$T/resume.json" --checkout "$T/checkout"
if (( rc == 0 )) && [ -f "$T/sentinel" ]; then
  pass "explicit matching resume passes"
else
  fail "explicit matching resume passes" "rc=$rc out=$out"
fi

reset; mkmanifest "$T/owned2.json"; attempt "$T/owned2.json" --checkout "$T/checkout"
rm -f "$T/sentinel"
mkmanifest "$T/badresume.json" resume="true" box="bx_someone_else"
attempt "$T/badresume.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ]; then
  pass "resume with a conflicting Box identity is rejected"
else
  fail "resume with a conflicting Box identity is rejected" "rc=$rc out=$out"
fi

reset
first="$(cat "$T/live-sha")"
echo more > "$T/checkout/file.txt"
git -C "$T/checkout" commit -qam second
printf '%s' "$first" > "$T/live-sha"
mkmanifest "$T/drift.json"
attempt "$T/drift.json" --checkout "$T/checkout"
if (( rc != 0 )) && [ ! -f "$T/sentinel" ] && echo "$out" | grep -qi "checkout HEAD"; then
  pass "checkout drift from the declared base fails before the sentinel"
else
  fail "checkout drift from the declared base fails before the sentinel" "rc=$rc out=$out"
fi
git -C "$T/checkout" reset -q --hard "$first"
printf '%s' "$(git -C "$T/checkout" rev-parse HEAD)" > "$T/live-sha"

# box-work gate: an invalid manifest stops before ANY Box call.
reset; mkmanifest "$T/gate-bad.json" branch="pc-976-fix-the-widget" title="[PC-976] Fix the widget output"
if BOX_CLI="$T/bin/box" GH_CLI="$T/bin/gh" "$BOXWORK" "$T/checkout" --manifest "$T/gate-bad.json" --agent pi "do work" >"$T/gate.log" 2>&1; then
  grc=0; else grc=$?; fi
if (( grc != 0 )) && [ ! -f "$T/box-called" ]; then
  pass "box-work with an invalid manifest makes no Box call"
else
  fail "box-work with an invalid manifest makes no Box call" "rc=$grc log=$(cat "$T/gate.log")"
fi

if [ ! -f "$T/box-called" ]; then
  pass "validator never invokes the Box CLI"
else
  fail "validator never invokes the Box CLI" "box was called"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit "$((FAIL > 0))"
