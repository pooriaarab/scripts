"""Ledger writer for directory-submit.

Writes rows in the fleet ledger shape (submissions/ledger.csv of
the fleet template repository): target, site, status, date, proof, retry_after, reason.
One row per (target, site). A new result replaces the old row.
"""
import csv
import datetime
import os
import re
import tempfile
from pathlib import Path

from lib import REPO

COLS = ["target", "site", "status", "date", "proof", "retry_after", "reason"]
STATUSES = ("submitted", "live", "blocked", "skipped")
SECRET_LIKE = re.compile(r"(?i)(password|passwd|secret|token|api[_-]?key|bearer)\s*[:=]")


def path():
    return Path(os.environ.get("DIRSUB_LEDGER", REPO / "submissions" / "ledger.csv"))


def load(p=None):
    p = p or path()
    if not p.exists():
        return []
    with open(p, newline="") as f:
        return list(csv.DictReader(f))


def record(target, site, status, note, retry_after="", today=None):
    """Write one result. `note` is proof for submitted/live and a reason for the rest."""
    if status not in STATUSES:
        raise ValueError(f"status must be one of {STATUSES}")
    if not note.strip():
        raise ValueError("every row needs a proof URL or a reason")
    if SECRET_LIKE.search(note):
        raise ValueError("note looks like a secret; nothing written")
    today = today or datetime.date.today().isoformat()
    proof, reason = (note, "") if status in ("submitted", "live") else ("", note)
    row = dict(target=target, site=site, status=status, date=today, proof=proof,
               retry_after=retry_after, reason=reason)
    rows = [r for r in load() if (r["target"], r["site"]) != (target, site)] + [row]
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=p.parent, suffix=".csv")
    with os.fdopen(fd, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    os.replace(tmp, p)


def pending(target, sites, today=None):
    """Sites with no row for the target, or a blocked row whose retry_after has passed."""
    today = today or datetime.date.today().isoformat()
    have = {r["site"]: r for r in load() if r["target"] == target}
    out = []
    for site in sites:
        r = have.get(site)
        if r is None or (r["status"] == "blocked" and r["retry_after"] and r["retry_after"] <= today):
            out.append(site)
    return out
