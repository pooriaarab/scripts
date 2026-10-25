#!/usr/bin/env python3
"""Look up board specs.

  python3 lookup.py fridayhunt            one board (slug or part of the name)
  python3 lookup.py --gate badge-required list boards by gate
  python3 lookup.py --method form-anon --free   free boards with no sign-in
  python3 lookup.py --verified filed -q   names only
"""
import argparse
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    for path in sorted(glob.glob(os.path.join(HERE, "*.jsonl"))):
        for line in open(path):
            yield json.loads(line)


ap = argparse.ArgumentParser()
ap.add_argument("name", nargs="?", help="slug or part of the board name")
ap.add_argument("--gate")
ap.add_argument("--method")
ap.add_argument("--verified", choices=["filed", "static-html", "registry-only"])
ap.add_argument("--free", action="store_true", help="only boards with a free path")
ap.add_argument("-q", action="store_true", help="print slug and target only")
args = ap.parse_args()

hits = []
for d in load():
    if args.name and args.name.lower() not in (d["slug"] + " " + d["target"]).lower():
        continue
    if args.gate and d.get("gate") != args.gate:
        continue
    if args.method and d.get("method") != args.method:
        continue
    if args.verified and d.get("verified") != args.verified:
        continue
    if args.free and not d.get("free_path"):
        continue
    hits.append(d)

for d in hits:
    print(f'{d["slug"]}\t{d["target"]}' if args.q or len(hits) > 1 else json.dumps(d, indent=2))
print(f"{len(hits)} board(s)")
