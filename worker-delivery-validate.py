#!/usr/bin/env python3
import base64, json, os, re, subprocess, sys
from datetime import datetime

fail = lambda msg: (print("worker-delivery-validate: FAIL: %s" % msg, file=sys.stderr) or sys.exit(1))
HEX40 = re.compile(r"^[0-9a-f]{40}$")
CLOSES = re.compile(r"(?i)\bcloses\s*:?\s*(?:([\w.-]+/[\w.-]+))?#([0-9]+)\b")
ANY_CLOSE = re.compile(r"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*(?:([\w.-]+/[\w.-]+))?#([0-9]+)\b")
TITLE_TAG = re.compile(r"^\[([A-Za-z]{2,4})-([1-9][0-9]*)\]\s+(.+)$")
ASSIST = re.compile(r"^[^\s:,]+:[^\s,]+$")
LOCKS = ("package-lock.json", "bun.lock", "bun.lockb", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock")
LOCK_INSTALL = {k: re.compile(v, re.I) for k, v in {
    "package-lock.json": r"\bnpm ci\b", "bun.lock": r"\bbun install\b.*--frozen-lockfile",
    "bun.lockb": r"\bbun install\b.*--frozen-lockfile", "pnpm-lock.yaml": r"\bpnpm install\b.*--frozen-lockfile",
    "yarn.lock": r"\byarn install\b.*--frozen-lockfile", "Cargo.lock": r"\bcargo fetch\b"}.items()}
FORGE_CMD = re.compile(r"(?i)^\s*(?:\\|(?:command|builtin)\s+)*(?:echo|printf|print)\b")
SEGMENT_SPLIT = re.compile(r"(&&|\|\||;|\|)")
BUCKET_OK = {"pass": {"success", "pass"}, "fail": {"failure", "fail", "cancelled", "timed_out", "action_required"},
             "pending": {"pending", "in_progress", "queued"}, "skipped": {"skipped", "skipping"}}
REQ = ("repository", "issue", "branch", "head", "tested_head", "outcome", "closing_ref", "implementation_status",
       "verification_commands", "setup_commands", "unresolved_failures", "claimed_counts", "assisted_by", "ci")
BOUND_SIZE = ("import {DEFAULT_CONFIG,validateConfig,summarizeFiles,checkSize,derivePrefix} from './pr-standards.mjs';"
    "const repoName=process.argv[2],overrides=JSON.parse(process.argv[3]||'{}'),config={...DEFAULT_CONFIG,...overrides};"
    "if(!config.prefix)config.prefix=derivePrefix(repoName);validateConfig(config);"
    "const files=JSON.parse(process.argv[1]),summary=summarizeFiles(files,config),size=checkSize(summary,config);"
    "console.log(JSON.stringify({summary,sizeFailures:size.failures,prefix:config.prefix}));")

def git(c, *a): return subprocess.run(["git", "-C", c, *a], text=True, capture_output=True)

def guaranteed_segments(cmd):
    guaranteed, segments = True, []
    for tok in SEGMENT_SPLIT.split(cmd):
        if tok == "||": guaranteed = False; continue
        if tok in ("&&", ";", "|"): guaranteed = True; continue
        if guaranteed and not FORGE_CMD.match(tok.strip()): segments.append(tok)
        guaranteed = True
    return segments

def gh_items(gh, path, key):
    out, page, total = [], 1, None
    while True:
        sep = "&" if "?" in path else "?"
        proc = subprocess.run([gh, "api", "%s%sper_page=100&page=%d" % (path, sep, page)], text=True, capture_output=True)
        if proc.returncode: fail("cannot read GitHub API %s: %s" % (path, proc.stderr.strip()))
        doc = json.loads(proc.stdout)
        if total is None and isinstance(doc, dict): total = doc.get("total_count")
        batch = doc.get(key, []) if key else (doc if isinstance(doc, list) else [])
        out.extend(batch)
        if not batch or (total is not None and len(out) >= total) or (total is None and len(batch) < 100): break
        page += 1
    return out

def bound_head(label, value, head):
    if not HEX40.match(value) or value != head: fail("bound %s head %s does not match checkout HEAD %s" % (label, value[:12] or "?", head[:12]))

def visible(text):
    out = re.sub(r"<!--[\s\S]*?-->", "", str(text or ""))
    out = re.sub(r"^ {0,3}(`{3,}|~{3,})[\s\S]*?^ {0,3}\1[ \t]*$", "", out, flags=re.M)
    return re.sub(r"`[^`\n]*`", "", out)

def fetch_config_overrides(gh, repo, base_ref):
    proc = subprocess.run([gh, "api", "repos/%s/contents/.github/pr-standards.json?ref=%s" % (repo, base_ref)], text=True, capture_output=True)
    if proc.returncode:
        if re.search(r"\b404\b|not found", proc.stderr, re.I): return {}
        fail("cannot read %s .github/pr-standards.json @ %s: %s" % (repo, base_ref, proc.stderr.strip()))
    doc = json.loads(proc.stdout)
    if doc.get("encoding") != "base64" or not isinstance(doc.get("content"), str):
        fail("%s .github/pr-standards.json must be a base64 contents payload" % repo)
    content = base64.b64decode(doc["content"]).decode("utf-8")
    if not content.strip(): fail("%s .github/pr-standards.json is empty" % repo)
    try: overrides = json.loads(content)
    except json.JSONDecodeError as exc: fail("%s .github/pr-standards.json contains invalid JSON: %s" % (repo, exc))
    if not overrides or isinstance(overrides, list) or not isinstance(overrides, dict):
        fail("%s .github/pr-standards.json must contain a JSON object" % repo)
    return overrides

def bound_size(root, repo, files, overrides):
    proc = subprocess.run(["node", "--input-type=module", "-e", BOUND_SIZE, json.dumps(files), repo.split("/")[-1], json.dumps(overrides)],
                          cwd=root, text=True, capture_output=True)
    if proc.returncode: fail("cannot compute counted size: %s" % proc.stderr.strip())
    doc = json.loads(proc.stdout)
    if doc.get("sizeFailures"):
        f = doc["sizeFailures"][0]
        fail("checkout exceeds bound: %s (expected %s)" % (f.get("got", "?"), f.get("expected", "?")))
    return doc["summary"], doc["prefix"]

def validate_live_pr(pr, issue, repo, prefix):
    if str(pr.get("state") or "").lower() != "open": fail("live PR is %s, not open for review" % (pr.get("state") or "?"))
    if pr.get("draft"): fail("live PR is a draft and not reviewable")
    title, body = str(pr.get("title") or ""), str(pr.get("body") or "")
    parsed = TITLE_TAG.match(title)
    if not parsed: fail("live PR title must match [%s-%d] subject format" % (prefix.upper(), issue))
    if parsed.group(1).upper() != prefix.upper() or int(parsed.group(2)) != issue:
        fail("live PR title issue tag does not match expected issue #%s" % issue)
    vis = visible(title + "\n" + body)
    all_refs, closes = ANY_CLOSE.findall(vis), CLOSES.findall(vis)
    if len(all_refs) != 1: fail("live PR must carry exactly one closing reference; found %d" % len(all_refs))
    if len(closes) != 1 or int(closes[0][1]) != issue: fail("live PR must close issue #%s with Closes exactly once" % issue)
    if closes[0][0] and closes[0][0].lower() != repo.lower(): fail("live PR closing reference targets wrong repo")

def validate(report_path):
    checkout, head = os.environ["CHECKOUT"], os.environ["CHECKOUT_HEAD"]
    checkout_branch, checkout_repo = os.environ["CHECKOUT_BRANCH"], os.environ["CHECKOUT_REPO"]
    base, pull, root, gh = os.environ["BASE_REF"], os.environ["PULL"].strip(), os.environ["ROOT"], os.environ.get("GH_CLI", "gh")
    expected_repo, expected_branch = os.environ["EXPECTED_REPOSITORY"].strip(), os.environ["EXPECTED_BRANCH"].strip()
    expected_issue, expected_outcome = int(os.environ["EXPECTED_ISSUE"]), os.environ["EXPECTED_OUTCOME"]
    bound_verify_cmd = os.environ.get("BOUND_VERIFY_CMD", "").strip()
    bound_verify_exit, bound_verify_head = os.environ.get("BOUND_VERIFY_EXIT", "").strip(), os.environ.get("BOUND_VERIFY_HEAD", "").strip()
    bound_setup_cmd = os.environ.get("BOUND_SETUP_CMD", "").strip()
    bound_setup_exit, bound_setup_head = os.environ.get("BOUND_SETUP_EXIT", "").strip(), os.environ.get("BOUND_SETUP_HEAD", "").strip()
    if not expected_repo or not expected_branch: fail("expected repository and branch are required")
    if not bound_verify_cmd or bound_verify_exit != "0": fail("bound verify command is required and must exit 0")
    bound_head("verify", bound_verify_head, head)
    try: doc = json.load(open(report_path, encoding="utf-8"))
    except Exception as exc: fail("invalid report JSON: %s" % exc)
    if doc.get("schema") != 1 or [k for k in REQ if k not in doc]: fail("report schema/fields invalid")
    issue, repo, branch = doc["issue"], str(doc["repository"]), str(doc["branch"])
    if type(issue) is not int or issue < 1 or issue != expected_issue: fail("report issue #%s does not match coordinator expected issue #%s" % (issue, expected_issue))
    if str(doc["outcome"]).strip() != expected_outcome.strip(): fail("report outcome does not match coordinator expected outcome")
    if repo.lower() != expected_repo.lower() or branch != expected_branch: fail("report repository/branch do not match coordinator contract")
    if checkout_repo.lower() != expected_repo.lower() or checkout_branch != expected_branch: fail("checkout repository/branch do not match coordinator contract")
    for field in ("head", "tested_head"):
        if not HEX40.match(str(doc[field])): fail("%s must be 40 lowercase hex" % field)
    if head != doc["head"] or doc["tested_head"] != head: fail("stale tested_head %s" % doc["tested_head"])
    dirty = git(checkout, "status", "--porcelain")
    if dirty.returncode: fail("cannot read checkout status: %s" % dirty.stderr.strip())
    if dirty.stdout.strip(): fail("checkout has uncommitted or untracked changes outside review scope")
    refs = CLOSES.findall(str(doc["closing_ref"]))
    if len(refs) != 1 or int(refs[0][1]) != issue: fail("closing_ref must contain exactly one Closes for issue #%s" % issue)
    if refs[0][0] and refs[0][0].lower() != repo.lower(): fail("closing_ref targets wrong repo")
    if str(doc["implementation_status"]) == "plan": fail("plan-only delivery is not implementation")
    if doc["implementation_status"] != "complete" or not str(doc["outcome"]).strip(): fail("outcome/implementation_status invalid")
    ver = doc["verification_commands"]
    if not isinstance(ver, list) or not ver or any(not isinstance(i, dict) or not str(i.get("command", "")).strip() or i.get("exit") != 0 for i in ver):
        fail("complete delivery requires verification_commands with exit 0")
    if not any(str(i.get("command", "")).strip() == bound_verify_cmd and i.get("exit") == 0 for i in ver):
        fail("report verification_commands do not match bound verify execution")
    if not isinstance(doc["unresolved_failures"], list): fail("unresolved_failures must be a list")
    if doc["unresolved_failures"]: fail("unresolved failures remain: %s" % "; ".join(map(str, doc["unresolved_failures"])))
    locks = [name for name in LOCKS if name in {p.rsplit("/", 1)[-1] for p in git(checkout, "ls-files").stdout.splitlines()}]
    if locks:
        if not bound_setup_cmd or bound_setup_exit != "0": fail("bound setup command is required when lockfiles are committed")
        bound_head("setup", bound_setup_head, head)
        segments = guaranteed_segments(bound_setup_cmd)
        if not segments: fail("bound setup command %r does not install; it only prints text" % bound_setup_cmd)
        bad = [name for name in locks if not any(LOCK_INSTALL[name].search(seg) for seg in segments)]
        if bad: fail("bound setup does not satisfy committed lockfiles: %s" % ", ".join(bad))
        setup = doc.get("setup_commands") or []
        if not any(str(i.get("command", "")).strip() == bound_setup_cmd and i.get("exit") == 0 for i in setup if isinstance(i, dict)):
            fail("report setup_commands do not match bound setup execution")
    claimed = doc["claimed_counts"]
    if not isinstance(claimed, dict) or any(k not in claimed or not isinstance(claimed[k], int) or claimed[k] < 0 for k in ("lines", "files")):
        fail("claimed_counts invalid")
    if not isinstance(doc["assisted_by"], list) or not doc["assisted_by"] or any(not ASSIST.match(str(x)) for x in doc["assisted_by"]):
        fail("assisted_by must list agent:model entries")
    if doc.get("merge_signed_off_by"): fail("merge_signed_off_by must not be set; root signoff cannot be inferred")
    if doc.get("merge_attribution") not in (None, "", "unknown"): fail("merge_attribution must be omitted or 'unknown'")
    proc = subprocess.run([gh, "api", "repos/%s/pulls/%s" % (expected_repo, pull)], text=True, capture_output=True)
    if proc.returncode: fail("cannot read GitHub API repos/%s/pulls/%s: %s" % (expected_repo, pull, proc.stderr.strip()))
    pr = json.loads(proc.stdout)
    pr_head = str(pr.get("head", {}).get("sha", "")); pr_branch = str(pr.get("head", {}).get("ref", ""))
    pr_repo = str((pr.get("head") or {}).get("repo", {}).get("full_name", "")); pr_base = str(pr.get("base", {}).get("sha", ""))
    pr_base_ref = str(pr.get("base", {}).get("ref") or base)
    if not HEX40.match(pr_head) or pr_head != head: fail("PR head %s does not match tested checkout head %s" % (pr_head[:12], head[:12]))
    if pr_branch != expected_branch or pr_repo.lower() != expected_repo.lower(): fail("PR repository/branch do not match coordinator contract")
    base_sha = git(checkout, "rev-parse", base).stdout.strip()
    if not HEX40.match(base_sha) or base_sha != pr_base: fail("PR base %s does not match coordinator base-ref %s" % (pr_base[:12], base_sha[:12]))
    overrides = fetch_config_overrides(gh, expected_repo, pr_base_ref)
    diff = git(checkout, "diff", "--numstat", "%s...HEAD" % base)
    if diff.returncode: fail("cannot diff checkout against %s: %s" % (base, diff.stderr.strip()))
    files = [{"filename": p[2], "additions": 0 if p[0] == "-" else int(p[0]), "deletions": 0 if p[1] == "-" else int(p[1])}
             for p in (line.split("\t") for line in diff.stdout.splitlines()) if len(p) == 3]
    actual, prefix = bound_size(root, expected_repo, files, overrides)
    validate_live_pr(pr, issue, repo, prefix)
    if claimed["lines"] != actual["countedLines"] or claimed["files"] != actual["countedFiles"]:
        fail("claimed %d/%d counted lines/files but checkout has %d/%d" % (claimed["lines"], claimed["files"], actual["countedLines"], actual["countedFiles"]))
    ci = doc["ci"]
    if not isinstance(ci, dict) or not HEX40.match(str(ci.get("head", ""))) or ci["head"] != head: fail("ci.head must match checkout HEAD")
    report_checks = ci.get("checks")
    if not isinstance(report_checks, list) or not report_checks: fail("ci.checks must list every verified check")
    live = {}; seq = [0]
    def when(value):
        if not value: return datetime.min
        try: return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError: return datetime.min
    def rank(item):
        seq[0] += 1
        rid = int(item.get("id") or 0)
        ts = when(item.get("started_at") or item.get("updated_at") or item.get("completed_at"))
        return (rid, ts.timestamp() if ts != datetime.min else 0, seq[0])
    def keep(key, r, bucket, source):
        cur = live.get(key)
        if not cur or r >= cur["rank"]: live[key] = {"bucket": bucket, "source": source, "rank": r}
    for item in gh_items(gh, "repos/%s/commits/%s/check-runs" % (expected_repo, pr_head), "check_runs"):
        name = str(item.get("name", "")).strip()
        if not name: continue
        status, conclusion = str(item.get("status", "")).lower(), str(item.get("conclusion") or "").lower()
        bucket = "pending" if status in BUCKET_OK["pending"] else "neutral" if conclusion == "neutral" else "skipped" if conclusion in BUCKET_OK["skipped"] else "pass" if conclusion in BUCKET_OK["pass"] else "fail" if conclusion in BUCKET_OK["fail"] or conclusion else "pending"
        keep("%s:%s" % ((item.get("app") or {}).get("id", "0"), name), rank(item), bucket, name)
    for item in gh_items(gh, "repos/%s/commits/%s/statuses" % (expected_repo, pr_head), None):
        context = str(item.get("context", "")).strip()
        if not context: continue
        state = str(item.get("state", "")).lower()
        bucket = "pass" if state in BUCKET_OK["pass"] else "skipped" if state in BUCKET_OK["skipped"] else "pending" if state in BUCKET_OK["pending"] else "fail"
        keep("status:%s" % context, rank(item), bucket, context)
    if not live: fail("no CI checks returned for PR head %s" % pr_head[:12])
    skip_policy = {}
    for entry in ci.get("expected_skipped") or []:
        if not isinstance(entry, dict): fail("ci.expected_skipped entries must be objects")
        n, r = str(entry.get("name", "")).strip(), str(entry.get("reason", "")).strip()
        if not n or not r: fail("ci.expected_skipped requires name and reason")
        skip_policy[n] = r
    report_by_name = {str(i.get("name", "")).strip(): str(i.get("bucket", "")).strip() for i in report_checks if str(i.get("name", "")).strip()}
    for name, bucket in report_by_name.items():
        if bucket not in BUCKET_OK: fail("ci check %r has invalid bucket" % name)
    live_by_name = {m["source"]: m["bucket"] for m in live.values()}
    for name in skip_policy:
        live_bucket = live_by_name.get(name)
        if live_bucket == "neutral": fail("ci.expected_skipped cannot approve neutral check %r" % name)
        if live_bucket != "skipped": fail("ci.expected_skipped %r is not a live skipped check" % name)
    for meta in live.values():
        name, live_bucket = meta["source"], meta["bucket"]
        if live_bucket == "neutral": fail("live CI not acceptable: %r is neutral" % name)
        if live_bucket in ("fail", "pending"): fail("live CI not acceptable: %r is %s" % (name, live_bucket))
        if live_bucket == "skipped":
            if name not in skip_policy: fail("skipped CI check %r requires ci.expected_skipped policy with reason" % name)
            continue
        reported = report_by_name.get(name)
        if reported is None: fail("report omitted live CI check %r" % name)
        if reported not in BUCKET_OK["pass"]: fail("false-green ci: %r reported as %s but latest check is %s" % (name, reported, live_bucket))
    for name in report_by_name:
        if not any(meta["source"] == name for meta in live.values()): fail("ci check %r is not present on PR head" % name)
    print("worker-delivery-validate: %s#%s delivery evidence valid at %s" % (expected_repo, issue, head[:12]))

if __name__ == "__main__": validate(sys.argv[1])
