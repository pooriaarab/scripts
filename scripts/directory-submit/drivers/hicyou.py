"""HiCyou: free submission after email magic-link sign-in (account the maker mailbox); manual review; badge optional."""
import re
import time
from drivers.kit import KIND
from lib import *

TARGET = "HiCyou"
DELAY = 10
RETRY_DAYS = 1
CAT = {"dev": "Development", "finance": "Finance", "health": "Health and Fitness", "education": "Education and Learning",
       "social": "Social", "transport": "Documents and Knowledge", "ecommerce": "Ecommerce",
       "realestate": "Documents and Knowledge", "other": "Documents and Knowledge"}
CAT_SITE = {"agentsandboxes": "AI Agent", "agentwalletindex": "AI Agent"}


def submit(site, p):
    go("https://hicyou.com/submit", wait=5)
    s = snap()
    if find(s, r'button "Sign in with Email"'):
        raise DriverFail("signed out")
    fill(s, r'textbox "Website URL', p["url"])
    click(must(snap(), r'button "Check website and continue"'))
    for _ in range(12):
        time.sleep(3)
        if find(snap(), r'textbox "Website Title'):
            break
    s = snap()
    if "already been submitted" in text(3000):
        return Result("submitted", "hicyou.com/submit: 'This website has already been submitted'")
    if not find(s, r'textbox "Website Title'):
        raise DriverFail("detail form did not open: " + say(text(300)))
    fill(s, r'textbox "Website Title', p["name"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 120))
    fill(s, r'textbox "Description', p["short"])
    select(0, CAT_SITE.get(site) or CAT[KIND[site]])
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    b("upload", "#f1", asset(site, "cover.png"))
    time.sleep(3)
    s = snap()
    ref = must(s, r'button "Submit Website"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(4000)
    m = re.search(r"Website submitted successfully[^\n]*", page)
    if m:
        return Result("submitted", f"hicyou.com/submit: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page[-600:], 300))
