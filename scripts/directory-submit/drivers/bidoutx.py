"""BidoutX: free listing behind the paid rankings, no account; modal with URL, category and 'List for free instead'."""
import json
import re
import subprocess
import time
from drivers.kit import KIND
from lib import *

TARGET = "BidoutX"
DELAY = 8
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Business, Finance & Legal", "health": "Health, Fitness & Wellness",
       "education": "Education & Learning", "social": "Social Media & Creator Tools", "transport": "Automotive & Transportation",
       "ecommerce": "Ecommerce & Retail", "realestate": "Business, Finance & Legal", "other": "Other"}
CAT_SITE = {"agentsandboxes": "AI Agents & Infrastructure", "agentwalletindex": "AI Agents & Infrastructure",
            "petcremation": "Other", "doulas": "Health, Fitness & Wellness"}


def jsclick(txt):
    return ev("(()=>{const e=[...document.querySelectorAll('button,[role=option],li,div,span')].filter(e=>e.innerText&&e.innerText.trim()===%s&&e.children.length<=2).pop();if(!e)return 'NONE';e.click();return 'OK'})()" % json.dumps(txt))


def submit(site, p):
    go("https://bidoutx.com/", wait=6)
    click(must(snap(), r'button "List Your Product Free"'))
    time.sleep(2)
    set_text("input[placeholder*='yourproduct']", p["url"])
    if "OK" not in str(jsclick("Choose a category")):
        raise DriverFail("category control not found")
    time.sleep(1)
    if "OK" not in str(jsclick(CAT_SITE.get(site) or CAT[KIND[site]])):
        raise DriverFail("category option not found")
    time.sleep(1)
    if not dry_run():
        if "OK" not in str(jsclick("List for free instead →")):
            raise DriverFail("free link not found")
    else:
        return Result("skipped", "dry run")
    time.sleep(6)
    page = ev("document.body.innerText")
    if "You're listed!" in str(page):
        host = p["url"].split("//")[1].rstrip("/")
        slug_ = re.sub(r"[^a-z0-9]+", "-", host.lower()).strip("-")
        code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "https://bidoutx.com/listing/" + slug_], capture_output=True, text=True).stdout
        return Result("live" if code == "200" else "submitted", f"bidoutx.com: \"You're listed! Your free listing is live on the board behind the paid rankings\" (listing page /listing/{slug_} returns {code})")
    raise DriverFail("no confirmation: " + say(str(page)[:400], 250))
