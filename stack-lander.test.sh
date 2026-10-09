#!/usr/bin/env bash
# Tests for stack-lander. Each row of stack-lander.failure-modes.md that is
# marked "tested" has a case here. A stub `gh` stands in for GitHub, and a
# local bare repository stands in for the remote, so nothing leaves the host.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

mkdir -p "$d/bin"
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"/issues "*) [ "${STUB_ISSUE_FAIL:-0}" = 1 ] && { echo "HTTP 403" >&2; exit 1; }; echo "${STUB_ISSUE:-42}" ;;
  *"/pulls "*) echo 7 ;;
  *"/check-runs"*) printf '%s\n' "${STUB_CHECKS-$DEFAULT_CHECKS}" ;;
  "pr create"*) echo "https://github.com/o/fox-thing/pull/8" ;;
esac
exit 0
EOF
chmod +x "$d/bin/gh"
export PATH="$d/bin:$SCRIPT_DIR:$PATH"
export GH_LOG="$d/gh.log"
export DEFAULT_CHECKS='[{"n":"ci","s":"completed","c":"success"}]'
export STACK_LANDER_POLL_SECONDS=0 STACK_LANDER_POLL_MAX=2
# Keep the host's global hooks and settings out of the fixture repos.
: > "$d/gitconfig"
export GIT_CONFIG_GLOBAL="$d/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
B=main

# Remote with one commit on main and no pr-standards config.
git init -q --bare -b "$B" "$d/origin.git"
git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
printf 'line\n' > "$d/seed/a.txt"
git -C "$d/seed" add -A && git -C "$d/seed" commit -qm init && git -C "$d/seed" push -q origin "$B"

git clone -q "$d/origin.git" "$d/work"
w="$d/work"
git -C "$w" checkout -q -b s-01-one
echo one > "$w/one.txt"; git -C "$w" add -A; git -C "$w" commit -qm one
git -C "$w" checkout -q -b s-02-two
echo two > "$w/two.txt"; git -C "$w" add -A; git -C "$w" commit -qm two
git -C "$w" checkout -q -b s-03-three
printf 'three\n' > "$w/a.txt"; git -C "$w" commit -qam three
git -C "$w" checkout -q s-01-one

q="$d/q"; mkdir -p "$q"
for n in 1 2 3; do
  printf '## Job\nDo it.\n' > "$q/$n-issue.md"
  printf 'Closes #ISSUE\n\n## What\nThing %s.\n' "$n" > "$q/$n-pr.md"
done
printf 's-01-one\tAdd the first file\t1-issue.md\t1-pr.md\tfeature\tstandard\n' > "$q/queue.tsv"
printf 's-02-two\tAdd the second file\t2-issue.md\t2-pr.md\tfeature\tstandard\n' >> "$q/queue.tsv"
printf 's-03-three\tChange the base file\t3-issue.md\t3-pr.md\tfeature\tstandard\n' >> "$q/queue.tsv"
cp "$q/queue.tsv" "$q/queue.bak"

land() { stack-lander --repo o/fox-thing --queue "$q/queue.tsv" --dir "$w" "$@"; }

# 1: entry does not exist.
: > "$GH_LOG"
land --entry 9 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "missing entry exits 1 with no gh call" || fail_msg "missing entry (rc $rc)"

# 2: body file missing.
mv "$q/1-pr.md" "$q/1-pr.bak"
: > "$GH_LOG"
land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "missing PR body exits 1 with no gh call" || fail_msg "missing body (rc $rc)"
mv "$q/1-pr.bak" "$q/1-pr.md"

# 3: title out of range.
sed '1s/Add the first file/Add/' "$q/queue.bak" > "$q/queue.tsv"
: > "$GH_LOG"
land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "short title exits 1 with no gh call" || fail_msg "short title (rc $rc)"
cp "$q/queue.bak" "$q/queue.tsv"

# 4: referenced attachment missing.
cp "$q/1-pr.md" "$q/1-pr.bak"
printf '\n![after](./1-after.png)\n' >> "$q/1-pr.md"
: > "$GH_LOG"
land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "missing attachment exits 1 with no gh call" || fail_msg "missing attachment (rc $rc)"
mv "$q/1-pr.bak" "$q/1-pr.md"

# 5: dirty checkout.
echo dirt >> "$w/one.txt"
: > "$GH_LOG"
land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "dirty checkout exits 1 with no gh call" || fail_msg "dirty checkout (rc $rc)"
git -C "$w" checkout -q -- one.txt

# 6: branch missing.
sed '1s/^s-01-one/s-01-gone/' "$q/queue.bak" > "$q/queue.tsv"
: > "$GH_LOG"
land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && ok "missing branch exits 1 with no gh call" || fail_msg "missing branch (rc $rc)"
cp "$q/queue.bak" "$q/queue.tsv"
rm -f "$q/queue.tsv.tips"

# 14: dry run prints calls and changes nothing.
: > "$GH_LOG"
before=$(git -C "$w" for-each-ref --format='%(refname) %(objectname)')
out=$(land --entry 1 --dry-run 2>&1); rc=$?
after=$(git -C "$w" for-each-ref --format='%(refname) %(objectname)')
if [ "$rc" -eq 0 ] && [ ! -s "$GH_LOG" ] && [ "$before" = "$after" ] && echo "$out" | grep -q "gh api repos/o/fox-thing/issues"; then
  ok "dry run prints the gh calls and changes no ref"
else
  fail_msg "dry run (rc $rc): $out"
fi

# 10: issue creation fails.
: > "$GH_LOG"
STUB_ISSUE_FAIL=1 land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && git -C "$w" show-ref -q --verify refs/heads/s-01-one && ok "failed issue creation leaves the branch alone" || fail_msg "issue failure (rc $rc)"

# 7 + happy path: no config on main, so the checker's derived prefix is used.
: > "$GH_LOG"
out=$(land --entry 1 2>&1); rc=$?
if [ "$rc" -eq 0 ] && git -C "$d/origin.git" show-ref -q --verify refs/heads/ft-42-one; then
  ok "entry 1 lands as ft-42-one (derived prefix) and is pushed"
else
  fail_msg "entry 1 (rc $rc): $out"
fi
grep -q 'title=\[FT-42\] Add the first file' "$GH_LOG" && ok "PR title carries [FT-42]" || fail_msg "PR title: $(cat "$GH_LOG")"
grep -q '/pulls ' "$GH_LOG" && ! grep -q 'pr create' "$GH_LOG" && ok "PR opens over REST when the body has no media" || fail_msg "REST PR open"

# 8: squash-merge entry 1 on the remote, add a config, then land entry 2.
git -C "$d/seed" pull -q origin "$B"
echo one > "$d/seed/one.txt"; mkdir -p "$d/seed/.github"
printf '{ "prefix": "abc" }\n' > "$d/seed/.github/pr-standards.json"
git -C "$d/seed" add -A && git -C "$d/seed" commit -qm "squash one" && git -C "$d/seed" push -q origin "$B"
: > "$GH_LOG"
out=$(STUB_ISSUE=43 land --entry 2 2>&1); rc=$?
n=$(git -C "$w" rev-list --count origin/main..abc-43-two 2>/dev/null || echo x)
if [ "$rc" -eq 0 ] && [ "$n" = 1 ]; then
  ok "entry 2 rebases --onto the squash and carries one commit, prefix from config"
else
  fail_msg "entry 2 (rc $rc, commits $n): $out"
fi

# 9: conflict. The remote changes a.txt, then entry 3 also changes it.
git -C "$d/seed" pull -q origin "$B"
printf 'remote\n' > "$d/seed/a.txt"; git -C "$d/seed" commit -qam remote; git -C "$d/seed" push -q origin "$B"
: > "$GH_LOG"
out=$(STUB_ISSUE=44 land --entry 3 2>&1); rc=$?
if [ "$rc" -eq 1 ] && ! git -C "$d/origin.git" show-ref -q --verify refs/heads/abc-44-three \
   && [ ! -d "$w/.git/rebase-merge" ] && [ ! -d "$w/.git/rebase-apply" ] && echo "$out" | grep -q RESUME_BRANCH; then
  ok "rebase conflict aborts, pushes nothing, and prints how to resume"
else
  fail_msg "conflict (rc $rc): $out"
fi

# 11 + 16: resume a pushed branch; a failing check exits 1 and skips the issue.
: > "$GH_LOG"
out=$(RESUME_BRANCH=ft-42-one ISSUE=42 STUB_CHECKS='[{"n":"ci","s":"completed","c":"failure"}]' land --entry 1 2>&1); rc=$?
[ "$rc" -eq 1 ] && ! grep -q '/issues ' "$GH_LOG" && ok "resume skips the issue; a failing check exits 1" || fail_msg "failing check (rc $rc): $out"

# 12: no check runs register within the budget.
: > "$GH_LOG"
RESUME_BRANCH=ft-42-one ISSUE=42 STUB_CHECKS='[]' land --entry 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no check runs within the budget exits 2" || fail_msg "timeout (rc $rc)"

# 13: no merge call in any run, and none in the tool.
if grep -qE 'pr merge|/merge' "$GH_LOG" || grep -qE 'gh pr merge|/merge' "$SCRIPT_DIR/stack-lander"; then
  fail_msg "a merge call exists"
else
  ok "no merge call exists"
fi

echo "# pass $pass fail $fail"
[ "$fail" -eq 0 ]
