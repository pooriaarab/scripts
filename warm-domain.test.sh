#!/usr/bin/env bash
# Offline tests for warm-domain. Stubs node and a fake toolkit; never sends.
set -uo pipefail

fail=0
pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/warm-domain"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/toolkit/scripts"
echo "// fake" > "$ROOT/toolkit/scripts/warmctl.mjs"

# A stub node that echoes its arguments, so we can assert what was exec'd
# without running the real CLI or touching the network.
cat > "$ROOT/bin/node" <<'STUB'
#!/usr/bin/env bash
echo "NODE:$*"
STUB
chmod +x "$ROOT/bin/node"

run() { PATH="$ROOT/bin:$PATH" WARM_DOMAIN_HOME="$ROOT/toolkit" "$SCRIPT" "$@" 2>&1; }

out=$(run --where)
[ "$out" = "$ROOT/toolkit" ] && ok "--where prints the resolved toolkit" || bad "--where printed: $out"

out=$(run report --config x.json)
case "$out" in
  NODE:*warmctl.mjs*report*--config*x.json*) ok "arguments are forwarded to warmctl" ;;
  *) bad "arguments not forwarded: $out" ;;
esac

# A missing toolkit must fail loudly with a non-zero status, not silently do
# nothing: a scheduler that sees exit 0 would report a warm-up that never ran.
out=$(PATH="$ROOT/bin:$PATH" WARM_DOMAIN_HOME="$ROOT/nonexistent" HOME="$ROOT/emptyhome" "$SCRIPT" report 2>&1)
st=$?
[ $st -ne 0 ] && ok "missing toolkit exits non-zero" || bad "missing toolkit exited 0"
case "$out" in *"cannot find warmctl.mjs"*) ok "missing toolkit explains itself" ;; *) bad "unclear error: $out" ;; esac

# --where must not require node, so it stays usable for diagnosis on a box
# where node is missing, which is exactly when you are looking for it.
out=$(PATH="/usr/bin:/bin" WARM_DOMAIN_HOME="$ROOT/toolkit" "$SCRIPT" --where 2>&1)
[ "$out" = "$ROOT/toolkit" ] && ok "--where works without node on PATH" || bad "--where needed node: $out"

echo
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
