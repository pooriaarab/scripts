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
    ("cr-1-ok-slug", {**base,"exemptBranches":["legacy\nmaster"]}, 1, "embedded newline in exemption fails closed"),
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


def test_dangling_pre_push_symlink_is_refused():
    """A dangling pre-push symlink must not be silently replaced.

    -e follows symlinks, so one whose target is missing reads as absent and
    --apply would treat "no hook installed" as license to overwrite it,
    destroying a symlink someone else's tooling put there.
    """
    import shutil, subprocess as sp
    d = tempfile.mkdtemp()
    repo = f"{d}/repo"
    os.makedirs(f"{repo}/.github")
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
    sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
    sp.run(["git", "-C", repo, "remote", "add", "origin",
            "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
    pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
    os.symlink(f"{d}/nonexistent-target", f"{repo}/.git/hooks/pre-push")
    out = sp.run([str(HERE / "install-pr-hooks"), "--apply", "--root", d],
                 capture_output=True, text=True, env=env).stdout
    still_symlink = os.path.islink(f"{repo}/.git/hooks/pre-push")
    shutil.rmtree(d, ignore_errors=True)
    ok = "SKIP" in out and still_symlink
    print(f"  {'OK ' if ok else 'FAIL'} dangling pre-push symlink refused")
    return ok


def test_symlinked_pre_push_is_refused_not_chmod_through():
    """A pre-push symlink must not be chmod'd through to its target.

    -f follows a symlink, so one pointing at an external file that happens to
    carry the exact version sentinel (e.g. a hook installed elsewhere by this
    same tool) would be read as "ours, but not executable" and chmod +x'd.
    chmod always follows a symlink to its target, so that would flip the
    execute bit on a file that can live anywhere on disk, outside this repo.
    """
    import shutil, subprocess as sp
    d = tempfile.mkdtemp()
    repo = f"{d}/repo"
    os.makedirs(f"{repo}/.github")
    target = f"{d}/external-hook"
    pathlib.Path(target).write_text(
        "#!/bin/bash\n"
        "# Installed by pooriaarab/scripts install-pr-hooks. Do not edit here; edit there.\n"
        "# install-pr-hooks v4\n"
    )
    os.chmod(target, 0o644)
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
    sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
    sp.run(["git", "-C", repo, "remote", "add", "origin",
            "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
    pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
    os.symlink(target, f"{repo}/.git/hooks/pre-push")
    out = sp.run([str(HERE / "install-pr-hooks"), "--apply", "--root", d],
                 capture_output=True, text=True, env=env).stdout
    target_untouched = (os.stat(target).st_mode & 0o111) == 0
    shutil.rmtree(d, ignore_errors=True)
    ok = "SKIP" in out and target_untouched
    print(f"  {'OK ' if ok else 'FAIL'} symlinked pre-push refused, not chmod'd through")
    return ok


def test_symlinked_root_is_scanned():
    """A --root that is itself a symlink to a directory must still be scanned.

    find runs without -L, so a symlink given as the search root is treated as
    a leaf and never descended into -- unless the root is resolved to its
    physical path first. Otherwise every repo under a symlinked --root (e.g.
    a stow/chezmoi-managed ~/Documents/Personal) goes silently unscanned
    while the run still reports success.
    """
    import shutil, subprocess as sp
    d = tempfile.mkdtemp()
    real = f"{d}/real"
    repo = f"{real}/repo"
    os.makedirs(f"{repo}/.github")
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
    sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
    sp.run(["git", "-C", repo, "remote", "add", "origin",
            "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
    pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
    os.symlink(real, f"{d}/linked-root")
    out = sp.run([str(HERE / "install-pr-hooks"), "--root", f"{d}/linked-root"],
                 capture_output=True, text=True, env=env).stdout
    shutil.rmtree(d, ignore_errors=True)
    ok = "INSTALL" in out and repo in out
    print(f"  {'OK ' if ok else 'FAIL'} symlinked --root is scanned")
    return ok


def test_deeply_nested_repo_is_scanned():
    """A repo nested deeper than the old fixed find depth must still be scanned.

    A prior version capped the scan with -maxdepth 4, so a repo any deeper
    than that went silently unscanned while the run still reported success.
    """
    import shutil, subprocess as sp
    d = tempfile.mkdtemp()
    repo = f"{d}/a/b/c/d/e/repo"
    os.makedirs(f"{repo}/.github")
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
    sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
    sp.run(["git", "-C", repo, "remote", "add", "origin",
            "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
    pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
    out = sp.run([str(HERE / "install-pr-hooks"), "--root", d],
                 capture_output=True, text=True, env=env).stdout
    shutil.rmtree(d, ignore_errors=True)
    ok = "INSTALL" in out and repo in out
    print(f"  {'OK ' if ok else 'FAIL'} deeply nested repo is scanned")
    return ok


if not test_symlinked_hook_dir_is_refused():
    sys.exit(1)

if not test_dangling_pre_push_symlink_is_refused():
    sys.exit(1)

if not test_symlinked_pre_push_is_refused_not_chmod_through():
    sys.exit(1)

if not test_symlinked_root_is_scanned():
    sys.exit(1)

if not test_deeply_nested_repo_is_scanned():
    sys.exit(1)


def test_eligibility_checks_the_push_url_too():
    """A repo that pushes somewhere else is not eligible, whatever it fetches from.

    This hook runs on push. remote.origin.pushurl can differ from the fetch URL,
    so checking only the fetch URL would install into a repo that pushes to a
    work remote -- the one thing this tool must never do. A remote can also carry
    more than one push URL, and git pushes to all of them, so every one of them
    has to be checked, not just the first.
    """
    import shutil, subprocess as sp
    results = []
    for label, pushurl, want in [
        ("no pushurl", None, True),
        ("personal pushurl", "git@github.com:pooriaarab/other.git", True),
        ("work pushurl", "git@github.com:some-employer/thing.git", False),
        ("explicit-port ssh", "ssh://git@github.com:22/pooriaarab/other.git", True),
        ("second pushurl is work", [
            "git@github.com:pooriaarab/other.git",
            "git@github.com:some-employer/thing.git",
        ], False),
    ]:
        d = tempfile.mkdtemp(); repo = f"{d}/repo"
        os.makedirs(f"{repo}/.github")
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null"}
        sp.run(["git", "-C", repo, "init", "-q"], check=True, env=env)
        sp.run(["git", "-C", repo, "remote", "add", "origin",
                "https://github.com/pooriaarab/testrepo.git"], check=True, env=env)
        if pushurl:
            urls = pushurl if isinstance(pushurl, list) else [pushurl]
            sp.run(["git", "-C", repo, "remote", "set-url", "--push", "origin", urls[0]],
                   check=True, env=env)
            for extra in urls[1:]:
                sp.run(["git", "-C", repo, "remote", "set-url", "--push", "--add", "origin", extra],
                       check=True, env=env)
        pathlib.Path(f"{repo}/.github/pr-standards.json").write_text('{"prefix":"tt"}')
        out = sp.run([str(HERE / "install-pr-hooks"), "--root", d],
                     capture_output=True, text=True, env=env).stdout
        eligible = "INSTALL" in out
        shutil.rmtree(d, ignore_errors=True)
        ok = eligible == want
        results.append(ok)
        print(f"  {'OK ' if ok else 'FAIL'} {label:<20} eligible={eligible} want={want}")
    return all(results)


if not test_eligibility_checks_the_push_url_too():
    ALL_OK = False

sys.exit(0 if ALL_OK else 1)
