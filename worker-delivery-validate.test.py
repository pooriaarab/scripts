#!/usr/bin/env python3
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
T = tempfile.mkdtemp(prefix="delivery-test.")
SCRIPT = os.environ.get("WORKER_DELIVERY_UNDER_TEST", os.path.join(ROOT, "worker-delivery-validate"))
repo, branch = "pooriaarab/scripts", "scr-311-validate-worker-delivery"
os.environ.update(PR_STANDARDS_ROOT=ROOT, DELIVERY_TEST_T=T, GH_CLI=os.path.join(T, "bin", "gh"))
os.makedirs(os.path.join(T, "bin"), exist_ok=True)
os.makedirs(os.path.join(T, "reports"), exist_ok=True)
open(os.path.join(T, "bin", "gh"), "w", encoding="utf-8").write("""#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = api ] || exit 9
p="${2:-}"
case "$p" in
  repos/*/pulls/*) cat "${DELIVERY_TEST_T:?}/pr.json" ;;
  repos/*/commits/*/check-runs*) [[ "$p" == *page=2* ]] && cat "${DELIVERY_TEST_T:?}/check-runs-page2.json" || cat "${DELIVERY_TEST_T:?}/check-runs.json" ;;
  repos/*/commits/*/statuses*) [[ "$p" == *page=2* ]] && cat "${DELIVERY_TEST_T:?}/statuses-page2.json" || cat "${DELIVERY_TEST_T:?}/statuses.json" ;;
  *) exit 9 ;; esac
""")
os.chmod(os.path.join(T, "bin", "gh"), 0o755)
os.environ["PATH"] = os.path.join(T, "bin") + os.pathsep + os.environ.get("PATH", "")
checkout = os.path.join(T, "checkout")
subprocess.run(["git", "init", "-q", checkout], check=True)
for key, val in (("user.email", "test@example.com"), ("user.name", "test"), ("commit.gpgsign", "false")):
    subprocess.run(["git", "-C", checkout, "config", key, val], check=True)
subprocess.run(["git", "-C", checkout, "remote", "add", "origin", f"https://github.com/{repo}.git"], check=True)
subprocess.run(["git", "-C", checkout, "checkout", "-qb", branch], check=True)
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
verify, outcome, issue, setup = "./worker-delivery-validate.test.sh", "Add worker-delivery-validate gate", 311, "npm ci"
bound = ["--bound-verify-command", verify, "--bound-verify-exit", "0", "--bound-verify-head", head,
         "--bound-setup-command", setup, "--bound-setup-exit", "0", "--bound-setup-head", head]
common = [SCRIPT, "--checkout", checkout, "--base-ref", base, "--pull", "313", "--expected-repository", repo,
          "--expected-branch", branch, "--expected-issue", str(issue), "--expected-outcome", outcome, *bound]
T0, T1, T2 = "2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z", "2026-01-01T00:00:02Z"

def check_run(rid, name, status="completed", conclusion="success", started=T0, app=1):
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion, "started_at": started, "app": {"id": app}}

def ci(checks, expected_skipped=None):
    out = {"head": head, "checks": checks}
    if expected_skipped:
        out["expected_skipped"] = expected_skipped
    return out

def doc(**over):
    p = {"schema": 1, "repository": repo, "issue": issue, "branch": branch, "head": head, "tested_head": head,
         "outcome": outcome, "closing_ref": "Closes #311", "implementation_status": "complete",
         "setup_commands": [{"command": setup, "exit": 0}], "verification_commands": [{"command": verify, "exit": 0}],
         "unresolved_failures": [], "claimed_counts": claimed, "assisted_by": ["cursor:composer-2.5"],
         "merge_attribution": "unknown", "ci": ci([{"name": "tests", "bucket": "pass"}])}
    p.update(over); return p

def write_ci(pr_head=head, pr_branch=branch, pr_base=base, checks=None, page2=None):
    checks = checks if checks is not None else [check_run(1, "tests")]
    page2 = page2 or []
    json.dump({"head": {"sha": pr_head, "ref": pr_branch, "repo": {"full_name": repo}}, "base": {"sha": pr_base, "ref": "main"}}, open(os.path.join(T, "pr.json"), "w"))
    json.dump({"total_count": len(checks) + len(page2), "check_runs": checks}, open(os.path.join(T, "check-runs.json"), "w"))
    json.dump({"check_runs": page2}, open(os.path.join(T, "check-runs-page2.json"), "w"))
    json.dump([], open(os.path.join(T, "statuses.json"), "w")); json.dump([], open(os.path.join(T, "statuses-page2.json"), "w"))

BUGBOT_SKIP = [{"name": "Cursor Bugbot", "reason": "draft-only advisory bot"}]
BOT = [check_run(10, "tests"), check_run(20, "Cursor Bugbot", conclusion="neutral", started=T1, app=99)]
SKIP_BOT = [check_run(10, "tests"), check_run(20, "Cursor Bugbot", conclusion="skipped", started=T1, app=99)]
reports = {"valid": doc(), "stale": doc(tested_head="a"*40), "prhead": doc(), "fg": doc(), "pend": doc(), "omit": doc(),
           "page2": doc(ci=ci([{"name": "tests", "bucket": "pass"}, {"name": "lint", "bucket": "pass"}])),
           "empty": doc(), "emptyrep": doc(ci=ci([])), "dirty": doc(), "issue": doc(issue=999, closing_ref="Closes #999"),
           "plan": doc(implementation_status="plan"), "setup": doc(setup_commands=[]),
           "forged": doc(setup_commands=[{"command": "echo 'npm ci'", "exit": 0}]),
           "bun": doc(setup_commands=[{"command": "npm ci", "exit": 0}]), "stalesetup": doc(), "staleverify": doc(),
           "fixes": doc(closing_ref="Fixes #311"), "verify": doc(), "defect": doc(unresolved_failures=["tests still fail locally"]),
           "big": doc(claimed_counts={"lines": 999, "files": 99}), "root": doc(merge_signed_off_by="root"),
           "repo": doc(repository="pooriaarab/other"), "branch": doc(branch="wrong-branch"), "neutral": doc(),
           "exskip": doc(ci=ci([{"name": "tests", "bucket": "pass"}], BUGBOT_SKIP)),
           "queued": doc(), "cancelwin": doc(ci=ci([{"name": "PR standards", "bucket": "pass"}]))}
for n, p in reports.items(): json.dump(p, open(os.path.join(T, "reports", n + ".json"), "w"))
ci_over = {"fg": {"checks": [check_run(1, "tests", conclusion="failure")]}, "pend": {"checks": [check_run(1, "tests", status="in_progress", conclusion=None)]},
           "omit": {"checks": [check_run(1, "tests"), check_run(2, "lint", conclusion="failure", started=T1)]},
           "page2": {"checks": [check_run(1, "tests")], "page2": [check_run(2, "lint", conclusion="failure", started=T2, app=2)]},
           "empty": {"checks": []}, "prhead": {"pr_head": "b"*40}, "branch": {"pr_branch": "wrong-branch"},
           "neutral": {"checks": BOT}, "exskip": {"checks": SKIP_BOT}, "exskipneutral": {"checks": BOT},
           "queued": {"checks": [check_run(10, "tests"), check_run(20, "tests", status="queued", conclusion=None, started=None)]},
           "cancelwin": {"checks": [check_run(10, "PR standards", conclusion="cancelled"), check_run(20, "PR standards", started=T2)]}}
cases = [
    ("valid delivery accepts bound checkout", "valid", (), 0, "delivery evidence valid"),
    ("stale tested_head is rejected", "stale", (), 1, "stale tested_head"),
    ("newer PR head with old report is rejected", "prhead", (), 1, "PR head"),
    ("false-green CI is rejected", "fg", (), 1, "live CI not acceptable"),
    ("pending CI reported as pass is rejected", "pend", (), 1, "live CI not acceptable"),
    ("failed omitted check is rejected", "omit", (), 1, "live CI not acceptable"),
    ("failed page-two check is rejected", "page2", (), 1, "live CI not acceptable"),
    ("empty CI check list is rejected", "empty", (), 1, "no CI checks"),
    ("empty report ci.checks is rejected", "emptyrep", (), 1, "ci.checks must list"),
    ("dirty checkout is rejected", "dirty", (), 1, "uncommitted or untracked"),
    ("wrong intended issue is rejected", "issue", (), 1, "expected issue"),
    ("plan-only delivery is rejected", "plan", (), 1, "plan-only"),
    ("missing setup evidence is rejected", "setup", (), 1, "bound setup"),
    ("forged quoted setup is rejected", "forged", (), 1, "bound setup"),
    ("absent bun.lock install is rejected", "bun", (), 1, "bound setup"),
    ("stale setup receipt is rejected", "stalesetup", ("--bound-setup-head", "a"*40), 1, "bound setup head"),
    ("stale verify receipt is rejected", "staleverify", ("--bound-verify-head", "a"*40), 1, "bound verify head"),
    ("Fixes closing reference is rejected", "fixes", (), 1, "exactly one Closes"),
    ("stale verification receipt is rejected", "verify", ("--bound-verify-exit", "1"), 1, "bound verify"),
    ("known unresolved defects block completion", "defect", (), 1, "unresolved"),
    ("oversized or wrong counted claim is rejected", "big", (), 1, "claimed"),
    ("inferred root merge signoff is rejected", "root", (), 1, "merge_signed_off_by"),
    ("wrong repository binding is rejected", "repo", (), 1, "coordinator contract"),
    ("wrong expected branch is rejected", "branch", (), 1, "coordinator contract"),
    ("neutral unresolved bot is rejected unconditionally", "neutral", (), 1, "is neutral"),
    ("expected skipped bot with reason is accepted", "exskip", (), 0, "delivery evidence valid"),
    ("expected_skipped cannot approve neutral", "exskipneutral", (), 1, "cannot approve neutral"),
    ("newer queued attempt blocks delivery", "queued", (), 1, "live CI not acceptable"),
    ("older cancelled attempt cannot replace later success", "cancelwin", (), 0, "delivery evidence valid"),
    ("missing expected-repository is rejected", "norepo", (), 2, "--expected-repository is required"),
]
dirty_path, bunlock, passed, failed = os.path.join(checkout, "dirty.txt"), os.path.join(checkout, "bun.lock"), 0, 0

def run_case(name, extra=(), after=None):
    over = ci_over.get(name, {}); case_head = head; args = common
    report_key = "exskip" if name == "exskipneutral" else name
    if name == "bun":
        open(bunlock, "w").write("{}\n"); subprocess.run(["git", "-C", checkout, "add", "bun.lock"], check=True)
        subprocess.run(["git", "-C", checkout, "commit", "-qm", "bun"], check=True)
        case_head = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True).strip()
        pl = json.load(open(os.path.join(T, "reports", "bun.json"))); pl["head"] = pl["tested_head"] = pl["ci"]["head"] = case_head
        json.dump(pl, open(os.path.join(T, "reports", "bun.json"), "w"))
        args = [SCRIPT, "--checkout", checkout, "--base-ref", base, "--pull", "313", "--expected-repository", repo,
                "--expected-branch", branch, "--expected-issue", str(issue), "--expected-outcome", outcome,
                "--bound-verify-command", verify, "--bound-verify-exit", "0", "--bound-verify-head", case_head,
                "--bound-setup-command", setup, "--bound-setup-exit", "0", "--bound-setup-head", case_head]
    write_ci(pr_head=over.get("pr_head", case_head), pr_branch=over.get("pr_branch", branch), checks=over.get("checks"), page2=over.get("page2"))
    if name == "norepo":
        proc = subprocess.run([SCRIPT, "--report", os.path.join(T, "reports", "valid.json"), "--checkout", checkout, "--pull", "313",
            "--expected-branch", branch, "--expected-issue", str(issue), "--expected-outcome", outcome,
            "--bound-verify-command", verify, "--bound-verify-exit", "0", "--bound-verify-head", head,
            "--bound-setup-command", setup, "--bound-setup-exit", "0", "--bound-setup-head", head], text=True, capture_output=True)
    else:
        proc = subprocess.run([*args, "--report", os.path.join(T, "reports", f"{report_key}.json"), *extra], text=True, capture_output=True)
    if after: after()
    return proc.returncode, proc.stdout + proc.stderr

try:
    for label, name, extra, want, needle in cases:
        after = None
        if name == "dirty":
            open(dirty_path, "w").write("x"); after = lambda: os.path.exists(dirty_path) and os.remove(dirty_path)
        if name == "bun":
            after = lambda: subprocess.run(["git", "-C", checkout, "reset", "--hard", head], check=True)
        rc, out = run_case(name, extra, after=after)
        if rc == want and needle.lower() in out.lower():
            print("ok -", label)
            passed += 1
        else:
            print("FAIL -", label)
            print(" ", "rc=%s out=%s" % (rc, out.strip()))
            failed += 1
finally:
    shutil.rmtree(T, ignore_errors=True)
print("\nResults: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
