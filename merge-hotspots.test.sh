#!/usr/bin/env bash
# Tests for merge-hotspots. Fixtures are temporary git repos with known churn.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
git init -q "$d"
git -C "$d" config user.email "t@t"
git -C "$d" config user.name "t"
echo base > "$d/busy.ts"
echo base > "$d/CHANGELOG.md"
echo base > "$d/quiet.ts"
git -C "$d" add -A && git -C "$d" commit -qm init
for i in $(seq 1 19); do echo "$i" >> "$d/busy.ts"; git -C "$d" commit -qam "busy $i"; done
for i in $(seq 1 14); do echo "$i" >> "$d/CHANGELOG.md"; git -C "$d" commit -qam "log $i"; done
echo x >> "$d/quiet.ts"; git -C "$d" commit -qam quiet

out=$(merge-hotspots "$d" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "merge-hotspots did not run (exit $rc): $out"
fi
if echo "$out" | grep -q "busy.ts" && echo "$out" | head -3 | grep -q "busy.ts"; then
  ok "busiest file ranks first"
else
  fail_msg "ranking — output: $out"
fi
if echo "$out" | grep -q "DERIVED.*CHANGELOG.md"; then
  ok "CHANGELOG.md is marked DERIVED"
else
  fail_msg "DERIVED marking — output: $out"
fi
if echo "$out" | grep -q "source.*busy.ts"; then
  ok "busy.ts is marked source"
else
  fail_msg "source marking — output: $out"
fi
if echo "$out" | grep -q "<<<"; then
  ok "files at >=5% get the <<< flag"
else
  fail_msg "<<< flag — output: $out"
fi
if echo "$out" | grep -q "churn is not contention"; then
  ok "output states churn is not contention"
else
  fail_msg "contention disclaimer — output: $out"
fi

small=$(mktemp -d)
trap 'rm -rf "$d" "$small"' EXIT
git init -q "$small"
git -C "$small" config user.email "t@t"
git -C "$small" config user.name "t"
echo x > "$small/a.txt"
git -C "$small" add -A && git -C "$small" commit -qm init
out=$(merge-hotspots "$small" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "tiny history — command did not run (exit $rc): $out"
elif echo "$out" | grep -q "SKIP"; then
  ok "tiny history is skipped"
else
  fail_msg "SKIP — output: $out"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
