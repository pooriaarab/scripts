"""JunkStartups: free listing; account the maker mailbox (magic link); 2-step wizard, then 'Submit for Review'."""
import re
import time
from drivers.kit import KIND, long_text
from lib import *

TARGET = "JunkStartups"
DELAY = 10
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Fintech", "health": "Health & Wellness", "education": "EdTech", "social": "Social",
       "transport": "SaaS", "ecommerce": "E-Commerce", "realestate": "SaaS", "other": "SaaS"}
CAT_SITE = {"agentsandboxes": "AI / ML", "agentwalletindex": "AI / ML"}


def submit(site, p):
    go("https://junkstartups.com/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if find(s, r'button "Sign In"') and not find(s, r'textbox "Website URL'):
        raise DriverFail("signed out")
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Startup name', p["name"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 78))
    click(must(snap(), r'button "Show all'))
    time.sleep(1)
    label = CAT_SITE.get(site) or CAT[KIND[site]]
    click(must(snap(), r'button "[A-Za-z0-9]+ ' + re.escape(label) + '"'))
    time.sleep(1)
    click(must(snap(), r'button "Continue"'))
    time.sleep(3)
    fill(snap(), r'textbox "Write your description', p["long"])
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(2)
    ref = must(snap(), r'button "Submit for Review"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(10)
    slug = None
    for _ in range(6):
        go("https://junkstartups.com/dashboard", wait=4)
        page = text(3000)
        if p["name"] in page:
            break
        time.sleep(5)
    m = re.search(re.escape(p["name"]) + r"\s*\n?\s*(APPROVED|PENDING[A-Z ]*|IN REVIEW|LIVE)", page)
    links = ev("[...document.querySelectorAll('a')].filter(a=>/View Live/i.test(a.innerText)).map(a=>a.href)")
    url = None
    if isinstance(links, list):
        for u in links:
            if site and re.search(r"/startups/", u):
                url = u
                break
    if m:
        return Result("live" if "APPROVED" in m.group(1) else "submitted", f"junkstartups.com dashboard: My Startups lists {p['name']} {m.group(1)}")
    raise DriverFail("startup not in dashboard: " + say(page, 300))
