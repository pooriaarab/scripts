#!/usr/bin/env python3
"""Turn `box list --json` into a sweep report.

Kept as a file rather than inlined in the shell: the report needs quoting that does not
survive being nested inside a heredoc, and a parse bug here reads as "no Boxes", which is
the one wrong answer that looks calm.
"""
import sys, json, os, datetime

max_age = float(os.environ.get("MAX_AGE_HOURS", "6"))
as_json = os.environ.get("JSON") == "1"
now = datetime.datetime.now(datetime.timezone.utc)

# The REST API returns every Box the account has ever had, including stopped and archived
# ones; `box list` hides those by default (its --filter defaults to running only). Counting
# them inflates the burn figure by an order of magnitude and makes the sweeper try to stop
# Boxes that cost nothing. Only these states bill.
BILLING_STATES = {"idle", "running", "pending", "stopping", "ready"}

boxes = [b for b in json.load(sys.stdin)["boxes"] if (b.get("state") or "") in BILLING_STATES]

over, no_deadline, under = [], [], []
burn = 0.0
for b in boxes:
    started = datetime.datetime.fromisoformat(b["createdAt"].replace("Z", "+00:00"))
    hours = (now - started).total_seconds() / 3600.0
    multiplier = b.get("billingMultiplier")
    rate = 0.036 * float(multiplier if multiplier is not None else 1)
    burn += rate
    row = {
        "id": b["id"],
        "state": b.get("state"),
        "age_hours": round(hours, 2),
        "environment": b.get("environment") or "-",
        # No deadline means nothing will ever stop it on its own.
        "deadline": b.get("archiveAfter") or "**none**",
        "cost_so_far": round(hours * rate, 3),
    }
    if hours > max_age:
        over.append(row)
    elif not b.get("archiveAfter"):
        no_deadline.append(row)
    else:
        under.append(row)

if as_json:
    print(json.dumps({"over": over, "no_deadline": no_deadline, "under": under,
                      "burn_per_hour": round(burn, 3)}, indent=2))
else:
    print("%d Box(es) running, burning $%.3f/hour. Ceiling %gh." % (len(boxes), burn, max_age))
    print()

    def table(title, rows):
        if not rows:
            return
        print("### " + title)
        print("| id | state | age (h) | env | deadline | cost so far |")
        print("|---|---|---|---|---|---|")
        for r in rows:
            print("| %s | %s | %s | %s | %s | $%s |" % (
                r["id"], r["state"], r["age_hours"], r["environment"], r["deadline"],
                r["cost_so_far"]))
        print()

    table("Over the %gh ceiling" % max_age, over)
    table("No deadline - nothing will ever stop these", no_deadline)
    table("Under the ceiling", under)

print("OVER_IDS=" + " ".join(r["id"] for r in over), file=sys.stderr)
