#!/usr/bin/env python3
"""Drive the generated pre-push hook, not the installer that writes it.

The hook is the thing that runs on every push, and it embeds its own copy of the
branch rule. That copy drifted from pr-standards.mjs once already: it accepted
cr-0-x and cr-007-x, imposed no slug length, and exempted master, which the
canonical validator does not. These cases pin the two together.
"""
import pathlib, subprocess, os, tempfile, json, sys
HERE = pathlib.Path(__file__).parent
src = (HERE / "install-pr-hooks").read_text()
k = "read -r -d '' HOOK_BODY <<'HOOK' || true\n"
body = src[src.index(k)+len(k):]
body = body[:body.index("\nHOOK\n")]
d = tempfile.mkdtemp(); os.makedirs(f"{d}/.github", exist_ok=True)
hook = f"{d}/pre-push"; pathlib.Path(hook).write_text(body + "\n"); os.chmod(hook, 0o755)
def push(branch, cfg):
    pathlib.Path(f"{d}/.github/pr-standards.json").write_text(json.dumps(cfg))
    line = f"refs/heads/{branch} abc refs/heads/{branch} 000\n"
    return subprocess.run(["bash", hook], cwd=d, input=line, capture_output=True, text=True).returncode
base = {"prefix": "cr"}
cases = [
    ("cr-142-fix-onboarding", base, 0, "valid branch"),
    ("cr-0-fix-it", base, 1, "issue zero"),
    ("cr-007-fix-it", base, 1, "leading zeros"),
    ("cr-1-ab", base, 1, "slug too short"),
    ("cr-1-"+"a"*49, base, 1, "slug too long"),
    ("cr-1-"+"a"*48, base, 0, "slug at the limit"),
    ("master", base, 1, "master no longer exempt"),
    ("main", base, 0, "main exempt"),
    ("release/1.2", base, 0, "release/* exempt"),
    ("chore/bump", base, 1, "chore refused by default"),
    ("chore/bump", {**base,"allowChoreEscape":True}, 0, "chore allowed when configured"),
    ("legacy", {**base,"exemptBranches":["legacy"]}, 0, "configured exemption honoured"),
    ("cr-1-ok-slug", {**base,"allowChoreEscape":"true"}, 1, "string bool fails closed"),
    ("cr-1-ok-slug", {**base,"exemptBranches":"legacy"}, 1, "string list fails closed"),
]
bad = 0
for branch, cfg, want, label in cases:
    got = push(branch, cfg)
    okk = (got != 0) == (want != 0)
    bad += 0 if okk else 1
    print(f"  {'OK ' if okk else 'FAIL'} {label:<32} exit={got} want={'reject' if want else 'accept'}")
print("ALL PASS" if bad == 0 else f"{bad} MISMATCH")
sys.exit(1 if bad else 0)
