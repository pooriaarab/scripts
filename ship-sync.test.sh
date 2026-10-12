#!/usr/bin/env bash
# Tests for ship-sync. Each row of ship-sync.failure-modes.md that is marked
# "tested" has a case here. A stub `gh` stands in for GitHub and a local bare
# repository stands in for the remote.
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
  *"/issues "*) [ "${STUB_ISSUE_FAIL:-0}" = 1 ] && { echo "HTTP 403" >&2; exit 1; }; echo 12 ;;
  *"/pulls "*) echo 13 ;;
esac
exit 0
EOF
chmod +x "$d/bin/gh"
export PATH="$d/bin:$SCRIPT_DIR:$PATH"
export GH_LOG="$d/gh.log"
: > "$GH_LOG"
: > "$d/gitconfig"
export GIT_CONFIG_GLOBAL="$d/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
M=main P=release

# Remote: production holds a squash of an older main, and main moved on.
git init -q --bare -b "$M" "$d/origin.git"
git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
s="$d/seed"
printf '{ "name": "pkg-x", "version": "0.1.0" }\n' > "$s/package.json"; echo 1 > "$s/a.txt"
git -C "$s" add -A; git -C "$s" commit -qm init
git -C "$s" branch "$P"
echo 2 > "$s/a.txt"; git -C "$s" commit -qam m1
echo 3 > "$s/a.txt"; printf '{ "name": "pkg-x", "version": "0.1.1" }\n' > "$s/package.json"; git -C "$s" commit -qam m2
git -C "$s" checkout -q "$P"; echo 2 > "$s/a.txt"; git -C "$s" commit -qam "squash m1"
git -C "$s" push -q origin "$M" "$P"

git clone -q "$d/origin.git" "$d/work"
w="$d/work"
sync() { (cd "$w" && ship-sync --repo o/pkg-x --prefix abc --assisted-by agent:model "$@"); }

# 1: missing --assisted-by.
(cd "$w" && ship-sync --repo o/pkg-x --prefix abc --issue 5) >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "missing --assisted-by exits 1" || fail_msg "usage (rc $rc)"

# 2: no issue and no --open.
sync >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "no --issue and no --open exits 1" || fail_msg "no issue (rc $rc)"

# 3: dirty checkout.
echo dirt >> "$w/a.txt"
sync --issue 5 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "dirty checkout exits 1" || fail_msg "dirty (rc $rc)"
git -C "$w" checkout -q -- a.txt

# 4: production branch missing.
sync --issue 5 --prod live >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "missing production branch exits 1" || fail_msg "missing prod (rc $rc)"

# 6: a slug with "release" in it.
sync --issue 5 --slug release-sync >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ! git -C "$w" show-ref -q --verify refs/heads/abc-5-release-sync \
  && ok "a branch name with 'release' exits 1" || fail_msg "release slug (rc $rc)"

# 7 + 10: build locally, write the body, push nothing.
: > "$GH_LOG"
out=$(sync --issue 5 --body-out "$d/body.md" 2>&1); rc=$?
b=abc-5-ship-sync
[ "$rc" -eq 0 ] && git -C "$w" show-ref -q --verify "refs/heads/$b" && ok "builds $b" || fail_msg "build (rc $rc): $out"
[ -z "$(git -C "$w" diff origin/main "$b")" ] && ok "branch tree equals main" || fail_msg "tree differs"
git -C "$w" merge-base --is-ancestor "origin/$P" "$b" && ok "production is a parent" || fail_msg "production not a parent"
[ ! -s "$GH_LOG" ] && ! git -C "$d/origin.git" show-ref -q --verify "refs/heads/$b" \
  && ok "without --open nothing is pushed and gh is not called" || fail_msg "side effects without --open"

git clone -q "$d/origin.git" "$d/check"
git -C "$d/check" checkout -q "$P"
if git -C "$d/check" merge -q --no-edit origin/main >/dev/null 2>&1; then
  fail_msg "fixture: plain main merge should conflict"
else
  git -C "$d/check" merge --abort
  ok "fixture: a plain main merge into production conflicts"
fi
git -C "$d/check" fetch -q "$w" "$b"
if git -C "$d/check" merge -q --no-edit FETCH_HEAD >/dev/null 2>&1 && [ -z "$(git -C "$d/check" diff origin/main HEAD)" ]; then
  ok "the ship-sync branch merges into production with no conflict and yields main"
else
  fail_msg "ship-sync branch does not merge clean"
fi

# 9: the body passes the checker's own body rules.
verdict=$(node -e '
  import(process.argv[1]).then((m) => {
    const body = require("fs").readFileSync(process.argv[2], "utf8");
    const r = m.validateBody(body, 5, m.DEFAULT_CONFIG);
    console.log(r.failures.length ? JSON.stringify(r.failures) : "clean");
  });' "$SCRIPT_DIR/pr-standards.mjs" "$d/body.md")
[ "$verdict" = clean ] && ok "the PR body passes validateBody" || fail_msg "body: $verdict"
grep -q 'pkg-x' "$d/body.md" && grep -q '0.1.1' "$d/body.md" && ok "the body names the package and version" || fail_msg "body content"

# 5: nothing to ship.
git -C "$s" checkout -q "$P"; git -C "$s" checkout -q "$M" -- .; git -C "$s" commit -qm "same tree"
git -C "$s" push -q origin "$P"
git -C "$w" checkout -q main
out=$(sync --issue 6 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -qi "nothing to ship" && ! git -C "$w" show-ref -q --verify refs/heads/abc-6-ship-sync \
  && ok "same tree prints nothing to ship and makes no branch" || fail_msg "nothing to ship (rc $rc): $out"
git -C "$s" checkout -q "$M"; echo 4 > "$s/a.txt"; git -C "$s" commit -qam m3; git -C "$s" push -q origin "$M"

# 11: --open with a failing issue call pushes nothing.
: > "$GH_LOG"
STUB_ISSUE_FAIL=1 sync --open >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ -z "$(git -C "$d/origin.git" for-each-ref refs/heads/abc-*)" ] \
  && ok "--open stops before the push when the issue call fails" || fail_msg "issue failure (rc $rc)"

# --open happy path: issue, push, PR into production over REST.
: > "$GH_LOG"
out=$(sync --open 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "diverged.*ahead 2" \
  && git -C "$d/origin.git" show-ref -q --verify refs/heads/abc-12-ship-sync \
  && grep -q '/pulls .*base=release' "$GH_LOG" && ok "--open creates the issue, pushes, and opens the PR into production" \
  || fail_msg "--open (rc $rc): $out / $(cat "$GH_LOG")"

# Fast-forward: release has no unique commits. Keep a stale local main to
# prove --open uses the remote head without pushing or resetting local refs.
git -C "$s" push -q --force origin "main~1:refs/heads/release"
git -C "$w" checkout -q main
before=$(git -C "$w" rev-parse HEAD)
refs_before=$(git -C "$d/origin.git" show-ref)
: > "$GH_LOG"
out=$(sync --issue 20 --body-out "$d/ff-body.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! git -C "$w" show-ref -q --verify refs/heads/abc-20-ship-sync \
  && [ "$(git -C "$w" rev-parse HEAD)" = "$before" ] && [ ! -s "$GH_LOG" ] \
  && ok "fast-forward dry run leaves refs and GitHub alone" || fail_msg "fast-forward dry run: $out"
grep -q 'behind 1, ahead 0' "$d/ff-body.md" && grep -q 'git merge-tree.*exit 0' "$d/ff-body.md" \
  && ok "fast-forward body records comparison and merge-tree evidence" || fail_msg "fast-forward evidence"
echo "$out" | grep -q 'fast-forward.*ahead 0' \
  && ok "fast-forward reports its path and reason" || fail_msg "fast-forward path output"
verdict=$(node -e '
  import(process.argv[1]).then((m) => {
    const body = require("fs").readFileSync(process.argv[2], "utf8");
    const r = m.validateBody(body, 20, m.DEFAULT_CONFIG);
    console.log(r.failures.length ? JSON.stringify(r.failures) : "clean");
  });' "$SCRIPT_DIR/pr-standards.mjs" "$d/ff-body.md")
[ "$verdict" = clean ] && ok "fast-forward body passes validateBody" || fail_msg "fast-forward body: $verdict"

: > "$GH_LOG"
out=$(sync --open --body-out "$d/ff-open.md" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '/issues ' "$GH_LOG" && grep -q '/pulls .*head=main .*base=release' "$GH_LOG" \
  && [ "$(git -C "$d/origin.git" show-ref)" = "$refs_before" ] \
  && ok "fast-forward opens from main and creates an issue without pushing" || fail_msg "fast-forward open: $out"
echo "$out" | grep -q "BRANCH=main SHA=$(git -C "$w" rev-parse origin/main)" \
  && ok "fast-forward reports the remote main SHA" || fail_msg "fast-forward SHA"

: > "$GH_LOG"
out=$(sync --open --issue 21 2>&1); rc=$?
[ "$rc" -eq 0 ] && ! grep -q '/issues ' "$GH_LOG" && grep -q '/pulls .*head=main .*base=release' "$GH_LOG" \
  && grep -q 'Closes #21' "$GH_LOG" && ! git -C "$w" show-ref -q --verify refs/heads/abc-21-ship-sync \
  && ok "fast-forward reuses the supplied issue" || fail_msg "fast-forward reuse: $out"

# A default branch not named main cannot be a head that pr-standards exempts: ours-merge path.
git -C "$s" push -q origin "main:refs/heads/trunk"
out=$(sync --main trunk --issue 22 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'ours-merge path.*default branch trunk is not named main' && ! echo "$out" | grep -q 'fast-forward path' \
  && ok "a default branch not named main takes the ours-merge path" || fail_msg "trunk path (rc $rc): $out"

# 12: no merge path.
if grep -qE 'pr merge|/merge' "$GH_LOG" || grep -qE 'gh pr merge|/merge' "$SCRIPT_DIR/ship-sync"; then
  fail_msg "a merge call exists"
else
  ok "no merge call exists"
fi

echo "# pass $pass fail $fail"
[ "$fail" -eq 0 ]
