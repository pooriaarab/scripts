#!/usr/bin/env python3
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
T = tempfile.mkdtemp(prefix="delivery-test.")
SCRIPT = os.environ.get("WORKER_DELIVERY_UNDER_TEST", os.path.join(ROOT, "worker-delivery-validate"))
os.environ.update(PR_STANDARDS_ROOT=ROOT, DELIVERY_TEST_T=T, GH_CLI=os.path.join(T, "bin", "gh"))
os.makedirs(os.path.join(T, "bin"), exist_ok=True)
os.makedirs(os.path.join(T, "reports"), exist_ok=True)
open(os.path.join(T, "bin", "gh"), "w", encoding="utf-8").write("""#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = api ] || exit 9
case "${2:-}" in
  repos/*/pulls/*) cat "${DELIVERY_TEST_T:?}/pr.json" ;;
  repos/*/commits/*/check-runs) cat "${DELIVERY_TEST_T:?}/check-runs.json" ;;
  repos/*/commits/*/status) cat "${DELIVERY_TEST_T:?}/status.json" ;;
  *) exit 9 ;; esac
""")
os.chmod(os.path.join(T, "bin", "gh"), 0o755)
os.environ["PATH"] = os.path.join(T, "bin") + os.pathsep + os.environ.get("PATH", "")
checkout = os.path.join(T, "checkout")
for cmd in (["git", "init", "-q", checkout],):
    subprocess.run(cmd, check=True)
for key, val in (("user.email", "test@example.com"), ("user.name", "test"), ("commit.gpgsign", "false")):
    subprocess.run(["git", "-C", checkout, "config", key, val], check=True)
subprocess.run(["git", "-C", checkout, "remote", "add", "origin", "https://github.com/pooriaarab/scripts.git"], check=True)
subprocess.run(["git", "-C", checkout, "checkout", "-qb", "scr-311-validate-worker-delivery"], check=True)
open(os.path.join(checkout, "base.txt"), "w").write("base\n")
subprocess.run(["git", "-C", checkout, "add", "base.txt"], check=True)
subprocess.run(["git", "-C", checkout, "commit", "-qm", "base"], check=True)
base = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True).strip()
open(os.path.join(checkout, "base.txt"), "a").write("work\n")
subprocess.run(["git", "-C", checkout, "add", "base.txt"], check=True)
subprocess.run(["git", "-C", checkout, "commit", "-qm", "work"], check=True)
open(os.path.join(checkout, "package-lock.json"), "w").write("{}\n")
subprocess.run(["git", "-C", checkout, "add", "package-lock.json"], check=True)
subprocess.run(["git", "-C", checkout, "commit", "-qm", "lock"], check=True)
head = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True).strip()
diff = subprocess.check_output(["git", "-C", checkout, "diff", "--numstat", f"{base}...HEAD"], text=True)
counted = json.loads(subprocess.check_output([
    "node", "--input-type=module", "-e",
    "import {summarizeFiles,DEFAULT_CONFIG} from './pr-standards.mjs';"
    "const files=[]; for (const line of process.argv[1].trim().split('\\n').filter(Boolean)) {"
    "const [a,d,n]=line.split('\\t'); files.push({filename:n,additions:+a,deletions:+d});}"
    "console.log(JSON.stringify(summarizeFiles(files,DEFAULT_CONFIG)));", diff,
], cwd=ROOT, text=True))
claimed = {"lines": counted["countedLines"], "files": counted["countedFiles"]}
verify, outcome, issue = "./worker-delivery-validate.test.sh", "Add worker-delivery-validate gate", 311
common = [SCRIPT, "--checkout", checkout, "--base-ref", base, "--pull", "313", "--expected-issue", str(issue), "--expected-outcome", outcome, "--bound-verify-command", verify, "--bound-verify-exit", "0"]

def ci(checks): return {"head": head, "checks": checks}
def doc(**over):
    payload = {"schema": 1, "repository": "pooriaarab/scripts", "issue": issue, "branch": "scr-311-validate-worker-delivery",
               "head": head, "tested_head": head, "outcome": outcome, "closing_ref": "Closes #311", "implementation_status": "complete",
               "setup_commands": [{"command": "npm ci", "exit": 0}], "verification_commands": [{"command": verify, "exit": 0}],
               "unresolved_failures": [], "claimed_counts": claimed, "assisted_by": ["cursor:composer-2.5"],
               "merge_attribution": "unknown", "ci": ci([{"name": "tests", "bucket": "pass"}])}
    payload.update(over); return payload

def write_ci(pr_head=head, checks=None, statuses=None):
    checks = checks if checks is not None else [{"name": "tests", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z", "app": {"id": 1}}]
    statuses = statuses if statuses is not None else []
    for name, payload in (("pr.json", {"head": {"sha": pr_head}}), ("check-runs.json", {"check_runs": checks}), ("status.json", {"statuses": statuses})):
        json.dump(payload, open(os.path.join(T, name), "w", encoding="utf-8"))

def run(name, extra=(), after=None):
    rep = os.path.join(T, "reports", f"{name}.json")
    proc = subprocess.run([*common, "--report", rep, *extra], text=True, capture_output=True)
    if after: after()
    return proc.returncode, proc.stdout + proc.stderr

reports = {"valid": doc(), "stale": doc(tested_head="a"*40), "prhead": doc(), "fg": doc(), "pend": doc(), "omit": doc(), "empty": doc(),
           "emptyrep": doc(ci=ci([])), "dirty": doc(), "issue": doc(issue=999, closing_ref="Closes #999"), "plan": doc(implementation_status="plan"),
           "setup": doc(setup_commands=[]), "echo": doc(setup_commands=[{"command": "echo no install needed", "exit": 0}]),
           "bun": doc(setup_commands=[{"command": "npm ci", "exit": 0}]), "verify": doc(), "defect": doc(unresolved_failures=["tests still fail locally"]),
           "big": doc(claimed_counts={"lines": 999, "files": 99}), "root": doc(merge_signed_off_by="root"), "repo": doc(repository="pooriaarab/other"), "ciok": doc()}
for name, payload in reports.items(): json.dump(payload, open(os.path.join(T, "reports", name + ".json"), "w", encoding="utf-8"))
ci_overrides = {"fg": {"checks": [{"name": "tests", "status": "completed", "conclusion": "failure", "started_at": "2026-01-01T00:00:00Z", "app": {"id": 1}}]},
                "pend": {"checks": [{"name": "tests", "status": "in_progress", "conclusion": None, "started_at": "2026-01-01T00:00:00Z", "app": {"id": 1}}]},
                "omit": {"checks": [{"name": "tests", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:00Z", "app": {"id": 1}},
                                    {"name": "lint", "status": "completed", "conclusion": "failure", "started_at": "2026-01-01T00:00:01Z", "app": {"id": 1}}]},
                "empty": {"checks": [], "statuses": []}, "prhead": {"pr_head": "b"*40}}
cases = [("valid delivery accepts bound checkout", "valid", (), 0, "delivery evidence valid"), ("stale tested_head is rejected", "stale", (), 1, "stale tested_head"),
         ("newer PR head with old report is rejected", "prhead", (), 1, "PR head"), ("false-green CI is rejected", "fg", (), 1, "live CI not acceptable"),
         ("pending CI reported as pass is rejected", "pend", (), 1, "live CI not acceptable"), ("failed omitted check is rejected", "omit", (), 1, "live CI not acceptable"),
         ("empty CI check list is rejected", "empty", (), 1, "no CI checks"), ("empty report ci.checks is rejected", "emptyrep", (), 1, "ci.checks must list"),
         ("dirty checkout is rejected", "dirty", (), 1, "uncommitted or untracked"), ("wrong intended issue is rejected", "issue", (), 1, "expected issue"),
         ("plan-only delivery is rejected", "plan", (), 1, "plan-only"), ("missing setup evidence is rejected", "setup", (), 1, "dependency install"),
         ("echo setup is rejected for lockfiles", "echo", (), 1, "dependency install"), ("absent bun.lock install is rejected", "bun", (), 1, "dependency install"),
         ("stale verification receipt is rejected", "verify", ("--bound-verify-exit", "1"), 1, "bound verify"), ("known unresolved defects block completion", "defect", (), 1, "unresolved"),
         ("oversized or wrong counted claim is rejected", "big", (), 1, "claimed"), ("inferred root merge signoff is rejected", "root", (), 1, "merge_signed_off_by"),
         ("wrong repository binding is rejected", "repo", (), 1, "repository"), ("valid delivery with matching CI passes", "ciok", (), 0, "delivery evidence valid")]
dirty_path, bunlock, passed, failed = os.path.join(checkout, "dirty.txt"), os.path.join(checkout, "bun.lock"), 0, 0
try:
    for label, name, extra, want, needle in cases:
        override = ci_overrides.get(name, {}); case_head = head; after = None
        if name == "dirty":
            open(dirty_path, "w").write("x")
            after = lambda: os.path.exists(dirty_path) and os.remove(dirty_path)
        if name == "bun":
            open(bunlock, "w").write("{}\n"); subprocess.run(["git", "-C", checkout, "add", "bun.lock"], check=True)
            subprocess.run(["git", "-C", checkout, "commit", "-qm", "bun"], check=True)
            case_head = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True).strip()
            payload = json.load(open(os.path.join(T, "reports", "bun.json"), encoding="utf-8"))
            payload["head"] = payload["tested_head"] = payload["ci"]["head"] = case_head
            json.dump(payload, open(os.path.join(T, "reports", "bun.json"), "w", encoding="utf-8"))
            after = lambda: subprocess.run(["git", "-C", checkout, "reset", "--hard", head], check=True)
        write_ci(pr_head=override.get("pr_head", case_head), checks=override.get("checks"), statuses=override.get("statuses"))
        rc, out = run(name, extra, after=after)
        if rc == want and needle.lower() in out.lower(): print("ok -", label); passed += 1
        else: print("FAIL -", label); print(" ", "rc=%s out=%s" % (rc, out.strip())); failed += 1
finally:
    shutil.rmtree(T, ignore_errors=True)
print("\nResults: %d passed, %d failed" % (passed, failed)); sys.exit(1 if failed else 0)
