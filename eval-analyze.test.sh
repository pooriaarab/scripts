#!/usr/bin/env bash
# End-to-end test for eval-analyze. Covers the analyzer rows marked "tested" in eval-matrix.failure-modes.md.
# Uses eval-matrix and a fake benchmark program to build fixtures. No network.
set -euo pipefail
cd "$(dirname "$0")"
M=./eval-matrix
A=./eval-analyze
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


plan() { # name groups-json
  cat > "$T/$1.json" <<EOF
{"packages": ["alpha", "beta"], "versions": ["0.1.0", "0.2.0"], "seed": 1, "bin": "$T/bin/{pkg}@{ver}", "cap_usd": 100, "groups": $2}
EOF
}
G_OK='[{"name":"trivial","provider":"openai","base_url":"http://127.0.0.1:1/v1","key":"x","models":["trivial-empty","trivial-yes"]},{"name":"hosted","provider":"openrouter","key_env":"TESTKEY","models":["good","mid","low","bad"]}]'
export TESTKEY=x
plan p2 "$G_OK"
$M run "$T/p2.json" "$T/o2" --workers 2 >/dev/null

# analyzer on o2: both versions, 4 complete models -> H1 sign test, H2, H3
out1=$($A "$T/o2" --old 0.1.0 --new 0.2.0 --boot 500)
echo "$out1" | grep -q "H1: old larger in 2, new larger in 0, tied 0" || fail "H1 counts: $out1"
echo "$out1" | grep -q "one-sided exact sign test p = 0.2500 (n = 2)" || fail "H1 p value"
echo "$out1" | grep -q "good .*+0.200" || fail "H2 good effect"
echo "$out1" | grep -q "median" || fail "H3 tau"
ok "the analyzer reports the sign test, the model effects and the rank correlation"

# 13. same input, same output
out2=$($A "$T/o2" --old 0.1.0 --new 0.2.0 --boot 500)
[ "$out1" = "$out2" ] || fail "13 output changed between runs"
ok "the bootstrap is reproducible"

# 10. a model with a missing cell is dropped
rm "$T/o2/beta@0.2.0/good.json"
out3=$($A "$T/o2" --old 0.1.0 --new 0.2.0 --boot 200)
echo "$out3" | grep -q "dropped: \['good'\]" || fail "10 dropped model: $out3"
ok "a model with a missing cell is dropped and listed"

# 11. a package with one version only
rm -rf "$T/o2/beta@0.2.0"
out4=$($A "$T/o2" --old 0.1.0 --new 0.2.0 --boot 200)
echo "$out4" | grep -q "left out (one version only): beta" || fail "11 one-version package: $out4"
ok "a package with one version is left out and listed"

# 12. all ties
plan p12 '[{"name":"trivial","provider":"openai","base_url":"http://127.0.0.1:1/v1","key":"x","models":["trivial-empty"]}]'
TIE=1 $M run "$T/p12.json" "$T/o12" >/dev/null
out5=$($A "$T/o12" --old 0.1.0 --new 0.2.0 --boot 100)
echo "$out5" | grep -q "sign test not computable (all tied)" || fail "12 ties: $out5"
ok "all ties give 'not computable', not p = 1"

echo "all $pass checks passed"
