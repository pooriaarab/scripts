#!/usr/bin/env python3
"""Run one directory driver over many sites, with a rate-limit stop and retries.

  python3 run.py <driver> [--sites a,b,c] [--delay SECONDS] [--retries N]
                 [--dry-run] [--confirm]

<driver> is a module in drivers/. It sets TARGET (the catalog name), DELAY
(seconds between sites), RETRY_DAYS (days to wait after a rate limit) and
defines submit(site, packet) -> Result. A driver may also define
confirm(sites) for a second step that needs the inbox.

Rules the loop keeps:
- A pair that has a ledger row is not filed again. A blocked row is filed again
  once its retry_after date has passed.
- The first RateLimited stops the loop. The site that hit it gets a blocked row
  with a retry_after date. The rest stay pending.
- A failed run (DriverFail) writes nothing, so the next run retries it.
Exit code: 0 all done, 1 some failed, 3 stopped by a rate limit.
"""
import argparse
import datetime
import importlib
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger  # noqa: E402
import lib  # noqa: E402


def all_sites():
    root = lib.REPO / "sites"
    return sorted(d.name for d in root.iterdir()
                  if not d.name.startswith("_") and (d / "data" / "submission.json").exists())


def run_one(mod, site, retries):
    for attempt in range(retries + 1):
        try:
            return mod.submit(site, lib.packet(site))
        except lib.DriverFail:
            if attempt == retries:
                raise
            time.sleep(5 * (attempt + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("driver")
    ap.add_argument("--sites", help="comma-separated site names; default is every site with a packet")
    ap.add_argument("--delay", type=float, help="seconds between sites; default is the driver's DELAY")
    ap.add_argument("--retries", type=int, default=1)
    ap.add_argument("--dry-run", action="store_true", help="fill forms, do not file, write no ledger row")
    ap.add_argument("--confirm", action="store_true", help="run the driver's confirm step instead")
    args = ap.parse_args()
    if args.dry_run:
        os.environ["DIRSUB_DRY_RUN"] = "1"

    mod = importlib.import_module(f"drivers.{args.driver}")
    sites = args.sites.split(",") if args.sites else all_sites()
    if args.confirm:
        try:
            mod.confirm(sites)
        except lib.DriverFail as e:
            print(f"FAIL {e}", file=sys.stderr)
            return 1
        return 0
    todo = sites if args.dry_run else ledger.pending(mod.TARGET, sites)
    delay = mod.DELAY if args.delay is None else args.delay
    print(f"{mod.TARGET}: {len(todo)} of {len(sites)} sites pending")

    failures = 0
    for i, site in enumerate(todo):
        try:
            res = run_one(mod, site, args.retries)
        except lib.RateLimited as e:
            retry = (datetime.date.today() + datetime.timedelta(days=mod.RETRY_DAYS)).isoformat()
            if not args.dry_run:
                ledger.record(mod.TARGET, site, "blocked", f"rate limit: {e}", retry_after=retry)
            print(f"{site}: RATE LIMITED, blocked until {retry}; stopping")
            return 3
        except lib.DriverFail as e:
            failures += 1
            print(f"{site}: FAIL {e}", file=sys.stderr)
            continue
        if not args.dry_run:
            ledger.record(mod.TARGET, site, res.status, res.note)
        print(f"{site}: {res.status} {res.note[:100]}")
        if i + 1 < len(todo):
            time.sleep(delay)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
