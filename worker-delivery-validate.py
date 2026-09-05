#!/usr/bin/env python3
import json, os, re, subprocess, sys
from datetime import datetime

fail = lambda msg: (print("worker-delivery-validate: FAIL: %s" % msg, file=sys.stderr) or sys.exit(1))
HEX40 = re.compile(r"^[0-9a-f]{40}$")
CLOSE = re.compile(r"(?i)\b(?:closes?|fix(?:es|ed)?|resolves?)\s*:?\s*(?:([\w.-]+/[\w.-]+))?#([0-9]+)\b")
ASSIST = re.compile(r"^[^\s:,]+:[^\s,]+$")
LOCKS = ("package-lock.json", "bun.lock", "bun.lockb", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock")
LOCK_INSTALL = {k: re.compile(v, re.I) for k, v in {
    "package-lock.json": r"\b(npm ci|npm install)\b", "bun.lock": r"\bbun install\b", "bun.lockb": r"\bbun install\b",
    "pnpm-lock.yaml": r"\bpnpm install\b", "yarn.lock": r"\byarn install\b", "Cargo.lock": r"\bcargo fetch\b"}.items()}
BUCKET_OK = {"pass": {"success", "pass"}, "fail": {"failure", "fail", "cancelled", "timed_out", "action_required"},
             "pending": {"pending", "in_progress", "queued"}, "skipped": {"skipped", "skipping", "neutral"}}
REQ = ("repository", "issue", "branch", "head", "tested_head", "outcome", "closing_ref", "implementation_status",
       "verification_commands", "setup_commands", "unresolved_failures", "claimed_counts", "assisted_by", "ci")

def git(checkout, *args):
    return subprocess.run(["git", "-C", checkout, *args], text=True, capture_output=True)

def gh_api(gh, path):
    proc = subprocess.run([gh, "api", path], text=True, capture_output=True)
    if proc.returncode: fail("cannot read GitHub API %s: %s" % (path, proc.stderr.strip()))
    return json.loads(proc.stdout)

def validate(report_path):
    checkout, head, branch, origin = os.environ["CHECKOUT"], os.environ["CHECKOUT_HEAD"], os.environ["CHECKOUT_BRANCH"], os.environ["CHECKOUT_REPO"]
    base, pull, root, gh = os.environ["BASE_REF"], os.environ["PULL"].strip(), os.environ["ROOT"], os.environ.get("GH_CLI", "gh")
    expected_issue, expected_outcome = int(os.environ["EXPECTED_ISSUE"]), os.environ["EXPECTED_OUTCOME"]
    bound_cmd, bound_exit = os.environ.get("BOUND_VERIFY_CMD", "").strip(), os.environ.get("BOUND_VERIFY_EXIT", "").strip()
    try: doc = json.load(open(report_path, encoding="utf-8"))
    except Exception as exc: fail("invalid report JSON: %s" % exc)
    if doc.get("schema") != 1 or [k for k in REQ if k not in doc]: fail("report schema/fields invalid")
    issue, repo = doc["issue"], str(doc["repository"])
    if not isinstance(issue, int) or issue < 1: fail("issue must be a positive integer")
    if issue != expected_issue: fail("report issue #%s does not match coordinator expected issue #%s" % (issue, expected_issue))
    if str(doc["outcome"]).strip() != expected_outcome.strip(): fail("report outcome does not match coordinator expected outcome")
    for field in ("head", "tested_head"):
        if not HEX40.match(str(doc[field])): fail("%s must be 40 lowercase hex" % field)
    if repo.lower() != origin.lower(): fail("report repository '%s' does not match checkout origin '%s'" % (repo, origin))
    if branch and branch != doc["branch"]: fail("report branch '%s' does not match checkout branch '%s'" % (doc["branch"], branch))
    if head != doc["head"]: fail("report head %s does not match checkout HEAD %s" % (doc["head"], head))
    if doc["tested_head"] != doc["head"] or doc["tested_head"] != head: fail("stale tested_head %s" % doc["tested_head"])
    dirty = git(checkout, "status", "--porcelain")
    if dirty.returncode: fail("cannot read checkout status: %s" % dirty.stderr.strip())
    if dirty.stdout.strip(): fail("checkout has uncommitted or untracked changes outside review scope")
    refs = CLOSE.findall(str(doc["closing_ref"]))
    if len(refs) != 1 or int(refs[0][1]) != issue: fail("closing_ref must close issue #%s" % issue)
    if refs[0][0] and refs[0][0].lower() != repo.lower(): fail("closing_ref targets wrong repo")
    if str(doc["implementation_status"]) == "plan": fail("plan-only delivery is not implementation")
    if doc["implementation_status"] != "complete" or not str(doc["outcome"]).strip(): fail("outcome/implementation_status invalid")
    ver = doc["verification_commands"]
    if not isinstance(ver, list) or not ver or any(not isinstance(i, dict) or not str(i.get("command", "")).strip() or i.get("exit") != 0 for i in ver):
        fail("complete delivery requires verification_commands with exit 0")
    if bound_cmd:
        if bound_exit != "0": fail("bound verify command exited %s" % (bound_exit or "?"))
        if not any(str(i.get("command", "")).strip() == bound_cmd and i.get("exit") == 0 for i in ver):
            fail("report verification_commands do not match bound verify execution")
    if doc["unresolved_failures"]: fail("unresolved failures remain: %s" % "; ".join(map(str, doc["unresolved_failures"])))
    tracked = set(git(checkout, "ls-files").stdout.splitlines())
    setup_cmds = [str(i.get("command", "")) for i in (doc.get("setup_commands") or []) if isinstance(i, dict) and i.get("exit") == 0]
    missing = [name for name in LOCKS if name in tracked and not any(LOCK_INSTALL[name].search(cmd) for cmd in setup_cmds)]
    if missing: fail("missing dependency install evidence for committed lockfiles: %s" % ", ".join(missing))
    claimed = doc["claimed_counts"]
    if not isinstance(claimed, dict) or any(k not in claimed or not isinstance(claimed[k], int) or claimed[k] < 0 for k in ("lines", "files")):
        fail("claimed_counts invalid")
    if not isinstance(doc["assisted_by"], list) or not doc["assisted_by"] or any(not ASSIST.match(str(x)) for x in doc["assisted_by"]):
        fail("assisted_by must list agent:model entries")
    if doc.get("merge_signed_off_by"): fail("merge_signed_off_by must not be set; root signoff cannot be inferred")
    if doc.get("merge_attribution") not in (None, "", "unknown"): fail("merge_attribution must be omitted or 'unknown'")
    diff = git(checkout, "diff", "--numstat", "%s...HEAD" % base)
    if diff.returncode: fail("cannot diff checkout against %s: %s" % (base, diff.stderr.strip()))
    files = [{"filename": p[2], "additions": int(p[0]), "deletions": int(p[1])} for p in (line.split("\t") for line in diff.stdout.splitlines()) if len(p) == 3 and p[0] != "-"]
    count = subprocess.run(["node", "--input-type=module", "-e",
        "import {summarizeFiles,DEFAULT_CONFIG} from './pr-standards.mjs';"
        "console.log(JSON.stringify(summarizeFiles(JSON.parse(process.argv[1]),DEFAULT_CONFIG)));", json.dumps(files)],
        cwd=root, text=True, capture_output=True)
    if count.returncode: fail("cannot compute counted size: %s" % count.stderr.strip())
    actual = json.loads(count.stdout)
    if claimed["lines"] != actual["countedLines"] or claimed["files"] != actual["countedFiles"]:
        fail("claimed %d/%d counted lines/files but checkout has %d/%d" % (claimed["lines"], claimed["files"], actual["countedLines"], actual["countedFiles"]))
    if actual["countedLines"] > 500 or actual["countedFiles"] > 40: fail("checkout exceeds 500 lines or 40 files")
    ci = doc["ci"]
    if not isinstance(ci, dict) or not HEX40.match(str(ci.get("head", ""))) or ci["head"] != head: fail("ci.head must match checkout HEAD")
    report_checks = ci.get("checks")
    if not isinstance(report_checks, list) or not report_checks: fail("ci.checks must list every verified check")
    pr_head = str(gh_api(gh, "repos/%s/pulls/%s" % (repo, pull)).get("head", {}).get("sha", ""))
    if not HEX40.match(pr_head): fail("cannot read PR head for %s#%s" % (repo, pull))
    if pr_head != head: fail("PR head %s does not match tested checkout head %s" % (pr_head[:12], head[:12]))
    live = {}
    def keep(key, when, bucket, source):
        cur = live.get(key)
        if not cur or when >= cur["when"]: live[key] = {"bucket": bucket, "source": source, "when": when}
    def when(value):
        if not value: return datetime.min
        try: return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError: return datetime.min
    for item in gh_api(gh, "repos/%s/commits/%s/check-runs" % (repo, pr_head)).get("check_runs") or []:
        name = str(item.get("name", "")).strip()
        if not name: continue
        status, conclusion = str(item.get("status", "")).lower(), str(item.get("conclusion") or "").lower()
        bucket = "pending" if status in BUCKET_OK["pending"] else "skipped" if conclusion in BUCKET_OK["skipped"] else "pass" if conclusion in BUCKET_OK["pass"] else "fail" if conclusion in BUCKET_OK["fail"] or conclusion else "pending"
        keep("%s:%s" % ((item.get("app") or {}).get("id", "0"), name), when(item.get("started_at")), bucket, name)
    for item in gh_api(gh, "repos/%s/commits/%s/status" % (repo, pr_head)).get("statuses") or []:
        context = str(item.get("context", "")).strip()
        if not context: continue
        state = str(item.get("state", "")).lower()
        bucket = "pass" if state in BUCKET_OK["pass"] else "skipped" if state in BUCKET_OK["skipped"] else "pending" if state in BUCKET_OK["pending"] else "fail"
        keep("status:%s" % context, when(item.get("updated_at")), bucket, context)
    if not live: fail("no CI checks returned for PR head %s" % pr_head[:12])
    report_by_name = {}
    for item in report_checks:
        name, bucket = str(item.get("name", "")).strip(), str(item.get("bucket", "")).strip()
        if bucket not in BUCKET_OK or not name: fail("ci check %r has invalid bucket" % name)
        report_by_name[name] = bucket
    for meta in live.values():
        name, live_bucket = meta["source"], meta["bucket"]
        if live_bucket in ("fail", "pending"): fail("live CI not acceptable: %r is %s" % (name, live_bucket))
        if live_bucket == "skipped": continue
        reported = report_by_name.get(name)
        if reported is None: fail("report omitted live CI check %r" % name)
        if reported not in BUCKET_OK["pass"]: fail("false-green ci: %r reported as %s but latest check is %s" % (name, reported, live_bucket))
    for name in report_by_name:
        if not any(meta["source"] == name for meta in live.values()): fail("ci check %r is not present on PR head" % name)
    print("worker-delivery-validate: %s#%s delivery evidence valid at %s" % (repo, issue, head[:12]))

if __name__ == "__main__": validate(sys.argv[1])
