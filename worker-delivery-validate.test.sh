#!/usr/bin/env bash
# Offline tests for worker-delivery-validate: git fixture repo, JSON reports, stub gh.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${WORKER_DELIVERY_UNDER_TEST:-$DIR/worker-delivery-validate}"
T="$(mktemp -d "${TMPDIR:-/tmp}/delivery-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/reports"
export PR_STANDARDS_ROOT="$DIR" DELIVERY_TEST_T="$T" GH_CLI="$T/bin/gh"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = pr ] && [ "${2:-}" = checks ] || exit 9
cat "${DELIVERY_TEST_T:?}/pr-checks.tsv"
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"
git init -q "$T/checkout"
git -C "$T/checkout" config user.email test@example.com
git -C "$T/checkout" config user.name test
git -C "$T/checkout" config commit.gpgsign false
git -C "$T/checkout" remote add origin https://github.com/pooriaarab/scripts.git
git -C "$T/checkout" checkout -qb scr-311-validate-worker-delivery
echo base > "$T/checkout/base.txt"
git -C "$T/checkout" add base.txt && git -C "$T/checkout" commit -qm base
BASE_SHA="$(git -C "$T/checkout" rev-parse HEAD)"
echo work >> "$T/checkout/base.txt" && git -C "$T/checkout" add base.txt && git -C "$T/checkout" commit -qm work
echo '{}' > "$T/checkout/package-lock.json" && git -C "$T/checkout" add package-lock.json && git -C "$T/checkout" commit -qm lock
HEAD_SHA="$(git -C "$T/checkout" rev-parse HEAD)"
BRANCH="scr-311-validate-worker-delivery"
ACTUAL="$(git -C "$T/checkout" diff --numstat "$BASE_SHA...HEAD" | node --input-type=module -e "
import {readFileSync} from 'node:fs'; import {summarizeFiles,DEFAULT_CONFIG} from './pr-standards.mjs';
const files=[]; for (const line of readFileSync(0,'utf8').trim().split('\n').filter(Boolean)) {
  const [a,d,n]=line.split('\t'); files.push({filename:n,additions:+a,deletions:+d});}
console.log(JSON.stringify(summarizeFiles(files,DEFAULT_CONFIG)));")"
LINES="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["countedLines"])' <<<"$ACTUAL")"
FILES="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["countedFiles"])' <<<"$ACTUAL")"
python3 - "$T" "$HEAD_SHA" "$BRANCH" "$LINES" "$FILES" "$SCRIPT" "$BASE_SHA" <<'PY'
import json, os, subprocess, sys
t, head, branch, lines, files, script, base = sys.argv[1:8]
base_doc = {
  "schema": 1, "repository": "pooriaarab/scripts", "issue": 311, "branch": branch,
  "head": head, "tested_head": head, "outcome": "Add worker-delivery-validate gate",
  "closing_ref": "Closes #311", "implementation_status": "complete",
  "setup_commands": [{"command": "echo no install needed", "exit": 0}],
  "verification_commands": [{"command": "./worker-delivery-validate.test.sh", "exit": 0}],
  "unresolved_failures": [], "claimed_counts": {"lines": int(lines), "files": int(files)},
  "assisted_by": ["cursor:composer-2.5"], "merge_attribution": "unknown",
}
def write(name, doc):
    json.dump(doc, open(os.path.join(t, "reports", name + ".json"), "w"))
def run(name, extra=(), checks="tests\tpass\t0s\thttps://x\n"):
    open(os.path.join(t, "pr-checks.tsv"), "w").write(checks)
    rep = os.path.join(t, "reports", name + ".json")
    cmd = [script, "--report", rep, "--checkout", os.path.join(t, "checkout"), "--base-ref", base, *extra]
    p = subprocess.run(cmd, text=True, capture_output=True)
    return p.returncode, p.stdout + p.stderr
write("valid", base_doc)
cases = [
  ("valid delivery accepts bound checkout", "valid", (), 0, "delivery evidence valid"),
  ("stale tested_head is rejected", "stale", (), 1, "stale tested_head"),
  ("false-green CI is rejected", "fg", ("--pull", "999"), 1, "false-green"),
  ("pending CI reported as pass is rejected", "pend", ("--pull", "999"), 1, "false-green"),
  ("plan-only delivery is rejected", "plan", (), 1, "plan-only"),
  ("missing setup evidence is rejected", "setup", (), 1, "setup"),
  ("known unresolved defects block completion", "defect", (), 1, "unresolved"),
  ("oversized or wrong counted claim is rejected", "big", (), 1, "claimed"),
  ("inferred root merge signoff is rejected", "root", (), 1, "merge_signed_off_by"),
  ("wrong repository binding is rejected", "repo", (), 1, "repository"),
  ("valid delivery with matching CI passes", "ciok", ("--pull", "999"), 0, "delivery evidence valid"),
]
d = dict(base_doc); d["tested_head"] = "a"*40; write("stale", d)
d = dict(base_doc); d["ci"] = {"head": head, "checks": [{"name": "tests", "bucket": "pass"}]}; write("fg", d)
d = dict(base_doc); d["ci"] = {"head": head, "checks": [{"name": "tests", "bucket": "pass"}]}; write("pend", d)
d = dict(base_doc); d["implementation_status"] = "plan"; write("plan", d)
d = dict(base_doc); d["setup_commands"] = []; write("setup", d)
d = dict(base_doc); d["unresolved_failures"] = ["tests still fail locally"]; write("defect", d)
d = dict(base_doc); d["claimed_counts"] = {"lines": 999, "files": 99}; write("big", d)
d = dict(base_doc); d["merge_signed_off_by"] = "root"; write("root", d)
d = dict(base_doc); d["repository"] = "pooriaarab/other"; write("repo", d)
d = dict(base_doc); d["ci"] = {"head": head, "checks": [{"name": "tests", "bucket": "pass"}]}; write("ciok", d)
checks = {"fg": "tests\tfail\t0s\thttps://x\n", "pend": "tests\tpending\t0s\thttps://x\n", "ciok": "tests\tpass\t0s\thttps://x\n"}
pass_n = fail_n = 0
for label, name, extra, want, needle in cases:
    rc, out = run(name, extra, checks.get(name, "tests\tpass\t0s\thttps://x\n"))
    if rc == want and needle.lower() in out.lower():
        print("ok -", label); pass_n += 1
    else:
        print("FAIL -", label); print(" ", "rc=%s out=%s" % (rc, out.strip())); fail_n += 1
print("\nResults: %d passed, %d failed" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)
PY
