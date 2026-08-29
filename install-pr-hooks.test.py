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
ALL_OK = bad == 0


def test_symlinked_hook_dir_is_refused():
    """A .git/hooks that is a symlink must not be followed.

    stow and chezmoi both symlink it. Following it writes the hook into a
    directory shared with other checkouts, including work ones. The containment
    check used to run only when core.hooksPath was set, so this path was open.
    """
    import shutil, subprocess as sp
    d = tempfile.mkdtemp()
    repo = f"{d}/repo"
    os.makedirs(f"{repo}/.github"); os.makedirs(f"{d}/shared-hooks")
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
    sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
    sp.run(["git", "-C", repo, "remote", "add", "origin",
            "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
    pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
    shutil.rmtree(f"{repo}/.git/hooks")
    os.symlink(f"{d}/shared-hooks", f"{repo}/.git/hooks")
    out = sp.run([str(HERE / "install-pr-hooks"), "--root", d],
                 capture_output=True, text=True, env=env).stdout
    shutil.rmtree(d, ignore_errors=True)
    ok = "SKIP" in out and "resolves outside the repo" in out
    print(f"  {'OK ' if ok else 'FAIL'} symlinked .git/hooks refused")
    return ok


if not test_symlinked_hook_dir_is_refused():
    sys.exit(1)

sys.exit(0 if ALL_OK else 1)
