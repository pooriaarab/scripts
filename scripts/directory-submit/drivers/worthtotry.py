"""WorthToTry: documented agent route POST /api/v1/submissions (no key), then Send for review in the owner's session."""
import json
import re
import subprocess
import time
from drivers.kit import values, KIND
from lib import *

TARGET = "WorthToTry"
DELAY = 8
RETRY_DAYS = 1
CATS = {"dev": ["Developer Tools", "AI", "Data"], "finance": ["Finance", "Data"], "health": ["Health & Fitness"],
        "education": ["Education"], "social": ["Lifestyle"], "transport": ["Travel", "Data"],
        "ecommerce": ["E-Commerce"], "realestate": ["Finance", "Data"], "other": ["Other"]}


def submit(site, p):
    body = {"url": p["url"], "email": CONTACT_EMAIL, "name": p["name"], "tagline": fit(p["tagline"], 58).rstrip("."),
            "description": fit(p["long"], 590), "categories": CATS[KIND[site]], "pricing": "free", "openSource": False}
    if dry_run():
        return Result("skipped", "dry run")
    r = subprocess.run(["curl", "-s", "-X", "POST", "https://worthtotry.com/api/v1/submissions", "-H",
                        "content-type: application/json", "-d", json.dumps(body)], capture_output=True, text=True)
    try:
        j = json.loads(r.stdout)
    except ValueError:
        raise DriverFail("API reply is not JSON: " + r.stdout[:200])
    if not j.get("ok"):
        raise DriverFail("API said: " + r.stdout[:300])
    slug = j["slug"]
    go(f"https://worthtotry.com/dashboard/tools/{slug}", wait=6)
    s = snap()
    ref = find(s, r'button "Send for review"')
    if not ref:
        raise DriverFail("no Send for review button for " + slug + ": " + say(text(300)))
    click(ref)
    time.sleep(6)
    page = text(1500)
    m = re.search(r"Sent for review[^\n]*", page)
    pub = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", f"https://worthtotry.com/tools/{slug}"],
                         capture_output=True, text=True).stdout
    if m and pub == "200":
        return Result("live", f"worthtotry.com/tools/{slug} returns 200; dashboard: '{say(m.group(0), 80)}' and {p['name']} LIVE")
    if m:
        return Result("submitted", f"worthtotry.com dashboard: '{say(m.group(0), 100)}'")
    raise DriverFail("no confirmation for " + slug + ": " + say(page, 300))
