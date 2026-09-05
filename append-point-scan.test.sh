#!/usr/bin/env bash
# Tests for append-point-scan. Each rule gets a positive control (must fire)
# and a negative control (must not). Fixtures are temporary git repos.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"

DIRS=""
mkrepo() {
  local d
  d=$(mktemp -d)
  DIRS="$DIRS $d"
  git init -q "$d"
  git -C "$d" config user.email "t@t"
  git -C "$d" config user.name "t"
  echo "$d"
}
commit_all() { git -C "$1" add -A >/dev/null; git -C "$1" commit -qm "$2"; }
trap 'rm -rf $DIRS' EXIT

# Run the scanner. A negative control may only claim a rule stayed quiet
# after this exits 0 — otherwise a wrapper that cannot execute (empty
# output, Permission denied) reports green.
scan() {
  out=$(append-point-scan "$1" 2>&1)
  rc=$?
}

# FRESHNESS-GATE positive: content-rabbit shape. Root package.json `ci`
# calls a :check script that has a :generate sibling. format:check is a
# prettier linter in the same manifest and must stay quiet.
d=$(mkrepo)
cat > "$d/package.json" <<'JSON'
{"scripts": {
  "ci": "bun run next-surface:check && turbo run lint",
  "next-surface:check": "node scripts/check.mjs --check --manifest s.json",
  "next-surface:generate": "node scripts/generate.mjs",
  "format:check": "prettier --check ."
}}
JSON
commit_all "$d" init
scan "$d"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "FRESHNESS-GATE" && echo "$out" | grep -q "next-surface:check" && ! echo "$out" | grep -q "format:check"; then
  ok "FRESHNESS-GATE fires on --check with a sibling generator"
else
  fail_msg "FRESHNESS-GATE positive — exit $rc output: $out"
fi

# FRESHNESS-GATE negative: format:check has no format:generate sibling.
d=$(mkrepo)
cat > "$d/package.json" <<'JSON'
{"scripts": {"format:check": "prettier --check ."}}
JSON
commit_all "$d" init
scan "$d"
if [ "$rc" -ne 0 ]; then
  fail_msg "format:check — scan did not run (exit $rc): $out"
elif echo "$out" | grep -q "FRESHNESS-GATE"; then
  fail_msg "format:check must not flag — output: $out"
else
  ok "format:check without a generate sibling does not flag"
fi

# ENUMERATED-SCRIPT positive: one script value over 400 chars.
d=$(mkrepo)
long=$(printf 'a%.0s' $(seq 1 410))
printf '{"scripts": {"test": "echo %s"}}' "$long" > "$d/package.json"
commit_all "$d" init
scan "$d"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ENUMERATED-SCRIPT"; then
  ok "ENUMERATED-SCRIPT fires past 400 chars"
else
  fail_msg "ENUMERATED-SCRIPT positive — exit $rc output: $out"
fi

# ENUMERATED-SCRIPT negative: short scripts stay quiet.
d=$(mkrepo)
echo '{"scripts": {"test": "vitest run", "lint": "eslint ."}}' > "$d/package.json"
commit_all "$d" init
scan "$d"
if [ "$rc" -ne 0 ]; then
  fail_msg "short scripts — scan did not run (exit $rc): $out"
elif echo "$out" | grep -q "ENUMERATED-SCRIPT"; then
  fail_msg "short scripts must not flag — output: $out"
else
  ok "short scripts do not flag"
fi

# ORDINAL-REGISTRY positive.
d=$(mkrepo)
mkdir -p "$d/migrations/meta"
echo '{}' > "$d/migrations/meta/_journal.json"
echo '{}' > "$d/package.json"
commit_all "$d" init
scan "$d"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ORDINAL-REGISTRY"; then
  ok "ORDINAL-REGISTRY fires on migrations/meta journal"
else
  fail_msg "ORDINAL-REGISTRY positive — exit $rc output: $out"
fi

# ORDINAL-REGISTRY negative.
d=$(mkrepo)
echo '{}' > "$d/package.json"
commit_all "$d" init
scan "$d"
if [ "$rc" -ne 0 ]; then
  fail_msg "repo without a journal — scan did not run (exit $rc): $out"
elif echo "$out" | grep -q "ORDINAL-REGISTRY"; then
  fail_msg "repo without a journal must not flag — output: $out"
else
  ok "repo without a journal does not flag"
fi

# COMMITTED-JUNK positive: tracked logs and tsbuildinfo.
d=$(mkrepo)
echo x > "$d/debug.log"
echo '{}' > "$d/tsconfig.tsbuildinfo"
echo '{}' > "$d/package.json"
commit_all "$d" init
scan "$d"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "COMMITTED-JUNK" && echo "$out" | grep -q "debug.log"; then
  ok "COMMITTED-JUNK fires on tracked logs"
else
  fail_msg "COMMITTED-JUNK positive — exit $rc output: $out"
fi

# COMMITTED-JUNK negative: untracked logs do not count.
d=$(mkrepo)
echo '{}' > "$d/package.json"
commit_all "$d" init
echo x > "$d/notes.log"
scan "$d"
if [ "$rc" -ne 0 ]; then
  fail_msg "untracked log — scan did not run (exit $rc): $out"
elif echo "$out" | grep -q "COMMITTED-JUNK"; then
  fail_msg "untracked log must not flag — output: $out"
else
  ok "untracked log does not flag"
fi

# Root package.json sorts first. git ls-tree lists apps/ and integrations/
# before the root file, so a naive head-N cap drops the one holding `ci`.
d=$(mkrepo)
cat > "$d/package.json" <<'JSON'
{"scripts": {"ci": "node ci.mjs --verify", "ci:build": "node build.mjs"}}
JSON
for i in $(seq 1 13); do
  mkdir -p "$d/apps/a$i" "$d/integrations/i$i"
  echo '{"scripts": {"t": "true"}}' > "$d/apps/a$i/package.json"
  echo '{"scripts": {"t": "true"}}' > "$d/integrations/i$i/package.json"
done
commit_all "$d" init
scan "$d"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "FRESHNESS-GATE" && echo "$out" | grep -q "package.json :: ci"; then
  ok "root package.json gate survives apps/ and integrations/ manifests"
else
  fail_msg "root manifest must win — exit $rc output: $out"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
