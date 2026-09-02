#!/usr/bin/env python3
"""Detect install/verify commands for Cursor Cloud environment.json."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Any


def gh_json(path: str) -> Any | None:
    proc = subprocess.run(
        ["gh", "api", path],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return json.loads(proc.stdout)


def root_files(owner: str, repo: str) -> set[str] | None:
    data = gh_json(f"repos/{owner}/{repo}/contents")
    if data is None:
        return None
    if isinstance(data, dict) and data.get("message"):
        return None
    return {item["name"] for item in data if item.get("type") == "file"}


def file_text(owner: str, repo: str, path: str) -> str | None:
    data = gh_json(f"repos/{owner}/{repo}/contents/{path}")
    if not data or "content" not in data:
        return None
    import base64

    return base64.b64decode(data["content"]).decode()


def detect_node(files: set[str], owner: str, repo: str) -> tuple[str, str]:
    if "pnpm-lock.yaml" in files:
        install = "pnpm install --frozen-lockfile"
    elif "bun.lockb" in files or "bun.lock" in files:
        install = "bun install"
    elif "package-lock.json" in files:
        install = "npm ci"
    elif "yarn.lock" in files:
        yarn_lock = file_text(owner, repo, "yarn.lock") or ""
        # Yarn Berry (2+) lockfiles carry a `__metadata:` block; Yarn Classic (1) doesn't
        # support `--immutable`, so pick the flag each version actually understands.
        install = (
            "yarn install --immutable"
            if "__metadata:" in yarn_lock
            else "yarn install --frozen-lockfile"
        )
    else:
        install = "npm install"

    verify = "npm test --if-present || npm run lint --if-present || npm run check --if-present || echo 'Add test/lint script'"
    pkg_raw = file_text(owner, repo, "package.json")
    if pkg_raw:
        try:
            pkg = json.loads(pkg_raw)
            scripts = pkg.get("scripts") or {}
            if scripts.get("check"):
                verify = "npm run check"
            elif scripts.get("test"):
                verify = "npm test"
            elif scripts.get("lint"):
                verify = "npm run lint"
            elif scripts.get("typecheck"):
                verify = "npm run typecheck"
            # bun/pnpm repos often use bun/pnpm directly
            if "bun.lockb" in files or "bun.lock" in files:
                if scripts.get("check"):
                    verify = "bun run check"
                elif scripts.get("test"):
                    verify = "bun run test"
                elif scripts.get("lint"):
                    verify = "bun run lint"
            if "pnpm-lock.yaml" in files:
                verify = verify.replace("npm ", "pnpm ")
        except json.JSONDecodeError:
            pass
    return install, verify


def detect_python(files: set[str]) -> tuple[str, str]:
    if "pyproject.toml" in files:
        install = 'pip install -e ".[dev]" 2>/dev/null || pip install -e . || pip install -r requirements.txt'
    else:
        install = "pip install -r requirements.txt"
    verify = "pytest -q 2>/dev/null || python -m pytest -q 2>/dev/null || make check 2>/dev/null || echo 'Add pytest or make check'"
    return install, verify


def detect_rust(_files: set[str]) -> tuple[str, str]:
    return "cargo fetch", "cargo test --no-run 2>/dev/null || cargo check"


def detect_go(_files: set[str]) -> tuple[str, str]:
    return "go mod download", "go test ./... 2>/dev/null || go vet ./..."


def _has_make_target(text: str, target: str) -> bool:
    return re.search(rf"(?m)^{re.escape(target)}:", text) is not None


def detect_make(files: set[str], owner: str, repo: str) -> tuple[str, str] | None:
    if "Makefile" not in files:
        return None
    text = file_text(owner, repo, "Makefile") or ""
    has_install = _has_make_target(text, "install")
    has_check = _has_make_target(text, "check")
    has_test = _has_make_target(text, "test")
    if not (has_install or has_check or has_test):
        # No relevant target: don't let a Makefile with unrelated rules (e.g. only
        # `uninstall:` or `docs:`) clobber a correctly detected ecosystem command.
        return None
    install = "make install" if has_install else "echo 'No make install target'"
    if has_check:
        verify = "make check"
    elif has_test:
        verify = "make test"
    else:
        verify = "echo 'Add make check'"
    return install, verify


def detect(owner: str, repo: str) -> dict[str, str]:
    files = root_files(owner, repo)
    if files is None:
        raise RuntimeError(f"cannot list root files for {owner}/{repo}")

    install = "echo 'No install step detected'"
    verify = "echo 'No test command detected'"

    if "package.json" in files:
        install, verify = detect_node(files, owner, repo)
    elif "pyproject.toml" in files or "requirements.txt" in files:
        install, verify = detect_python(files)
    elif "Cargo.toml" in files:
        install, verify = detect_rust(files)
    elif "go.mod" in files:
        install, verify = detect_go(files)

    make_pair = detect_make(files, owner, repo)
    if make_pair and "package.json" not in files:
        install, verify = make_pair

    return {"install": install, "verify": verify}


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: cursor-cloud-detect.py <owner> <repo>", file=sys.stderr)
        sys.exit(2)
    owner, repo = sys.argv[1], sys.argv[2]
    try:
        print(json.dumps(detect(owner, repo)))
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
