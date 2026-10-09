#!/usr/bin/env bash
# Tests for file-dep-restack. Each row of file-dep-restack.failure-modes.md
# that is marked "tested" has a case here. The lock command is a stub, so no
# test needs pnpm or the network.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
: > "$d/gitconfig"
export GIT_CONFIG_GLOBAL="$d/gitconfig"
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The stub lock command counts its runs and writes a lockfile from package.json.
export COUNT="$d/lock-runs"
lock="sh -c 'echo run >> \"\$COUNT\"; cksum package.json > pnpm-lock.yaml'"

r="$d/repo"
git init -q -b main "$r"
cd "$r" || exit 1
c() { GIT_AUTHOR_NAME="${AN:-t}" GIT_AUTHOR_EMAIL="${AE:-t@t}" git commit -q "$@"; }
cat > package.json <<'EOF'
{
  "name": "app",
  "dependencies": {
    "pkg-a": "file:/abs/pkg-a",
    "pkg-local": "file:/abs/pkg-local"
  }
}
EOF
echo lock0 > pnpm-lock.yaml; echo readme > README.md
git add -A; c -m init

git checkout -q -b s-01-one
echo "fails when x" > failure-modes.md; git add -A
AN=Ann AE=ann@example.com c -m "Add failure modes first"
node -e 'const f="package.json",p=JSON.parse(require("fs").readFileSync(f));p.devDependencies={"pkg-b":"file:/abs/pkg-b"};require("fs").writeFileSync(f,JSON.stringify(p,null,2)+"\n")'
echo code > impl.js; echo b-lock > pnpm-lock.yaml; git add -A; c -m "Add the implementation"
git checkout -q -b s-02-two
echo more > more.js; git add -A; c -m "Add more"

git checkout -q -b newbase main
echo base-readme > README.md; echo base-lock > pnpm-lock.yaml; git add -A; c -m "Land something else"
git checkout -q s-02-two

printf 's-00-zero\t%s\ns-01-one\t%s\ns-02-two\t%s\n' "$(git rev-parse main)" "$(git rev-parse s-01-one)" "$(git rev-parse s-02-two)" > "$d/tips"

restack() { file-dep-restack --base newbase --packages pkg-a,pkg-b --range '^0.1.0' \
  --alias 'pkg-b=npm:pkg-b-renamed@^0.2.0' --lock-cmd "$lock" "$@"; }
refs() { git for-each-ref --format='%(refname) %(objectname)' refs/heads; }

# 1: usage.
file-dep-restack --base newbase main s-01-one >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "missing --packages exits 1" || fail_msg "usage (rc $rc)"

# 2: dirty checkout.
echo dirt >> README.md
before=$(refs); restack main s-01-one s-02-two >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$before" = "$(refs)" ] && ok "dirty checkout exits 1 and moves nothing" || fail_msg "dirty (rc $rc)"
git checkout -q -- README.md

# 3: missing branch.
before=$(refs); restack main s-01-one s-09-gone >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$before" = "$(refs)" ] && ok "missing branch exits 1 and moves nothing" || fail_msg "missing branch (rc $rc)"

# 4: not a stack.
before=$(refs); restack main s-02-two s-01-one >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$before" = "$(refs)" ] && ok "out-of-order branches exit 1 and move nothing" || fail_msg "not a stack (rc $rc)"

# 7: lock command fails.
before=$(refs)
file-dep-restack --base newbase --packages pkg-a --lock-cmd false main s-01-one s-02-two >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$before" = "$(refs)" ] && ok "failing lock command exits 1 and moves nothing" || fail_msg "lock failure (rc $rc)"
[ "$(git rev-parse --abbrev-ref HEAD)" = s-02-two ] && ok "returns to the starting branch after a failure" || fail_msg "start branch not restored"

# Happy path, rows 6 and 9-13 and 15 (and 18: an untracked stray file).
: > "$COUNT"
echo "not part of any commit" > stray-untracked.txt
out=$(restack --tips "$d/tips" main s-01-one s-02-two 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "restack exits 0" || fail_msg "restack (rc $rc): $out"
git merge-base --is-ancestor newbase s-02-two && ok "the stack sits on the new base" || fail_msg "not on new base"
subjects=$(git log --reverse --format=%s newbase..s-02-two | tr '\n' '|')
[ "$subjects" = "Add failure modes first|Add the implementation|Add more|" ] && ok "commits replay one by one in order" || fail_msg "order: $subjects"
author=$(git log --format='%an <%ae>' --grep='Add failure modes first' newbase..s-02-two)
[ "$author" = "Ann <ann@example.com>" ] && ok "author is kept" || fail_msg "author: $author"
pj=$(git show s-02-two:package.json)
echo "$pj" | grep -q '"pkg-a": "\^0.1.0"' && ok "file: dep in --packages becomes the range" || fail_msg "range: $pj"
echo "$pj" | grep -q '"pkg-b": "npm:pkg-b-renamed@\^0.2.0"' && ok "--alias spec replaces the range" || fail_msg "alias: $pj"
echo "$pj" | grep -q '"pkg-local": "file:/abs/pkg-local"' && ok "file: dep outside --packages is left alone" || fail_msg "local dep: $pj"
git show s-01-one:pnpm-lock.yaml | grep -q "$(git show s-01-one:package.json | cksum | cut -d' ' -f1)" \
  && ok "a lockfile conflict resolves by regenerating" || fail_msg "lockfile: $(git show s-01-one:pnpm-lock.yaml)"
git log --name-only --format= newbase..s-02-two | grep -qx stray-untracked.txt \
  && fail_msg "an untracked file was committed by the replay" || ok "an untracked file in the checkout is never committed"
rm -f stray-untracked.txt
runs=$(wc -l < "$COUNT" | tr -d ' ')
[ "$runs" = 2 ] && ok "lockfile regenerates only when package.json changes" || fail_msg "lock runs: $runs"
[ "$(sed -n 1p "$d/tips" | cut -f2)" = "$(git rev-parse newbase)" ] && [ "$(sed -n 3p "$d/tips" | cut -f2)" = "$(git rev-parse s-02-two)" ] \
  && ok "--tips points at the new base and the new tips" || fail_msg "tips: $(cat "$d/tips")"

# 5: real conflict outside package files.
git checkout -q -b s-03-clash main
echo clash > README.md; git add -A; c -m clash
before=$(refs); restack main s-03-clash >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$before" = "$(refs)" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = s-03-clash ] \
  && ok "a real conflict exits 1, moves nothing, and restores the branch" || fail_msg "real conflict (rc $rc)"

echo "# pass $pass fail $fail"
[ "$fail" -eq 0 ]
