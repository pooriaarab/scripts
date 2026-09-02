#!/usr/bin/env python3
"""Build environment.json from detected install/verify commands."""

from __future__ import annotations

import json
import sys


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "usage: cursor-cloud-environment-json.py <repo> <install> <verify>",
            file=sys.stderr,
        )
        sys.exit(2)
    repo, install, verify = sys.argv[1], sys.argv[2], sys.argv[3]
    name = f"{repo} Cloud Environment"
    payload = {
        "name": name,
        "install": install,
        "start": "echo 'Environment ready for cloud agents'",
        "terminals": [
            {
                "name": "Verify",
                "command": verify,
                "description": "Run tests/lint before opening PRs",
            }
        ],
    }
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
