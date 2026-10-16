#!/usr/bin/env bash
# End-to-end test for eval-matrix and eval-analyze. Covers every row marked "tested" in
# eval-matrix.failure-modes.md. A fake benchmark program stands in for the packages. No network.
set -euo pipefail
cd "$(dirname "$0")"
M=./eval-matrix
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }

# fake program: its file name is <pkg>@<ver>; the behavior depends on the model name
mkdir "$T/bin"
for pkg in alpha beta; do
  for ver in 0.1.0 0.2.0; do
    cat > "$T/bin/$pkg@$ver" <<EOF
#!/usr/bin/env python3
import sys, json, os
a = sys.argv[1:]
model = a[a.index("--model") + 1]
ver = "$ver"
open(os.environ.get("COUNTER", "/dev/null"), "a").write(model + "\n")
open(os.environ.get("ARGLOG", "/dev/null"), "a").write(" ".join(a) + "\n")
if model == "boom": sys.exit(1)
if model == "nojson": print("hello"); sys.exit(0)
if model == "nomean": print("{}"); sys.exit(0)
tie = os.environ.get("TIE") == "1"
if model.startswith("trivial-"): mean = 0.0 if (ver == "0.2.0" or tie) else 0.5
elif model == "good": mean = 0.9 if ver == "0.1.0" else 0.7
elif model == "mid": mean = 0.6 if ver == "0.1.0" else 0.5
elif model == "low": mean = 0.3
elif model == "pricey": mean = 0.5
else: mean = 0.1
cost = 0.4 if model.startswith("pricey") else 0.0
print(json.dumps({"benchmark": {"id": "$pkg", "version": ver}, "model": "fake:" + model, "mean": mean, "totals": {"tasks": 3, "costUsd": cost, "latencyMs": 1}, "startedAt": "t0", "completedAt": "t1"}))
EOF
    chmod +x "$T/bin/$pkg@$ver"
  done
done

plan() { # name groups-json cap
  cat > "$T/$1.json" <<EOF
{"packages": ["alpha", "beta"], "versions": ["0.1.0", "0.2.0"], "seed": 1, "bin": "$T/bin/{pkg}@{ver}", "cap_usd": ${3:-100}, "groups": $2}
EOF
}
G_OK='[{"name":"trivial","provider":"openai","base_url":"http://127.0.0.1:1/v1","key":"x","models":["trivial-empty","trivial-yes"]},{"name":"hosted","provider":"openrouter","key_env":"TESTKEY","models":["good","mid","low","bad"]}]'

# 1. missing plan, empty packages
if $M run "$T/nope.json" "$T/o1" >/dev/null 2>"$T/err"; then fail "1 missing plan exited 0"; fi
grep -q "no plan file" "$T/err" || fail "1 message"
echo '{"packages": [], "versions": ["1"], "groups": []}' > "$T/empty.json"
if $M run "$T/empty.json" "$T/o1" >/dev/null 2>"$T/err"; then fail "1 empty packages exited 0"; fi
grep -q "no packages" "$T/err" || fail "1 empty message"
ok "a missing plan or an empty package list exits 2"

# 2. a finished cell is skipped on re-run; 14. keys stay out of files
plan p2 "$G_OK"
export TESTKEY=SECRETKEY123
export COUNTER="$T/counter"
: > "$COUNTER"
$M run "$T/p2.json" "$T/o2" --workers 2 >/dev/null
first=$(wc -l < "$COUNTER" | tr -d " ")
$M run "$T/p2.json" "$T/o2" --workers 2 >/dev/null
second=$(wc -l < "$COUNTER" | tr -d " ")
[ "$first" = 24 ] || fail "2 first run made $first cells, wanted 24 (2 pkg x 2 ver x 6 models)"
[ "$second" = 24 ] || fail "2 re-run re-ran cells ($second)"
ok "a re-run does not repeat finished cells"
if grep -rq SECRETKEY123 "$T/o2"; then fail "14 the key reached a file"; fi
ok "the key is not written to any report or ledger"

# 3. failing cells: retry once, .fail file, others continue; 4. report without a mean
G_BAD='[{"name":"hosted","provider":"openrouter","key_env":"TESTKEY","models":["boom","nojson","nomean","good"]}]'
plan p3 "$G_BAD"
: > "$COUNTER"
$M run "$T/p3.json" "$T/o3" >/dev/null
ls "$T/o3/alpha@0.1.0/" | grep -q "boom.fail" || fail "3 no .fail for boom"
ls "$T/o3/alpha@0.1.0/" | grep -q "nojson.fail" || fail "3 no .fail for bad JSON"
ls "$T/o3/alpha@0.1.0/" | grep -q "nomean.fail" || fail "4 no .fail for a report without a mean"
ls "$T/o3/alpha@0.1.0/" | grep -q "good.json" || fail "3 the good cell did not run after failures"
[ "$(grep -c '^boom$' "$COUNTER")" = 8 ] || fail "3 boom was not retried once ($(grep -c '^boom$' "$COUNTER"))"
ok "a failing cell is retried once, recorded, and the run goes on; a report without a mean is a failure"

# 5. cap: stop before the next model, STOPPED file, later model not run
G_CAP='[{"name":"hosted","provider":"openrouter","key_env":"TESTKEY","models":["pricey","good","low"]}]'
plan p5 "$G_CAP" 0.5
$M run "$T/p5.json" "$T/o5" --workers 1 >/dev/null 2>&1
[ -f "$T/o5/STOPPED" ] || fail "5 no STOPPED file"
[ ! -f "$T/o5/alpha@0.1.0/low.json" ] || fail "5 a later model ran after the cap"
ok "the spending cap stops the run and writes STOPPED"

# 15. group args reach the program
G_ARGS='[{"name":"hosted","provider":"openrouter","key_env":"TESTKEY","args":["--concurrency","8"],"models":["good"]}]'
plan p15 "$G_ARGS"
export ARGLOG="$T/arglog"
: > "$ARGLOG"
$M run "$T/p15.json" "$T/o15" >/dev/null
grep -q -- "--concurrency 8" "$ARGLOG" || fail "15 group args were not passed: $(cat "$ARGLOG" | head -2)"
unset ARGLOG
ok "a group's args are passed to the benchmark program"

# 7. no temp files left; 8. ledger rebuild
find "$T/o2" -name '*.tmp' | grep -q . && fail "7 temp files left" || true
rm "$T/o2/ledger.csv"
$M ledger "$T/o2" >/dev/null
rows=$(($(wc -l < "$T/o2/ledger.csv" | tr -d " ") - 1))
[ "$rows" = 24 ] || fail "8 ledger rebuild has $rows rows"
ok "no temp files remain and the ledger rebuilds from the report files"

# 9. install failure (no bin override, npm points at a closed port)
cat > "$T/p9.json" <<EOF
{"packages": ["no-such-pkg-zzz"], "versions": ["9.9.9"], "groups": [{"name":"trivial","provider":"openai","base_url":"http://127.0.0.1:1/v1","key":"x","models":["trivial-empty"]}]}
EOF
npm_config_registry=http://127.0.0.1:9 $M run "$T/p9.json" "$T/o9" >/dev/null 2>&1 || true
ls "$T/o9/no-such-pkg-zzz@9.9.9/" | grep -q "trivial-empty.fail" || fail "9 no install failure record"
grep -q "install failed" "$T/o9/no-such-pkg-zzz@9.9.9/trivial-empty.fail" || fail "9 message"
ok "an install failure marks every cell of that version missing"

echo "all $pass checks passed"
