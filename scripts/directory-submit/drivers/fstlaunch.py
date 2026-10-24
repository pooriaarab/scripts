"""fstlaunch: free plan; account the maker mailbox via magic link, then a startup form with a PNG logo."""
import re
import time
from drivers.kit import values, KIND
from lib import *

TARGET = "fstlaunch"
DELAY = 8
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Fintech", "health": "Health & Wellness", "education": "Education",
       "social": "Social", "transport": "Other", "ecommerce": "E-commerce", "realestate": "Other", "other": "Other"}


def submit(site, p):
    v = values(p)
    go("https://fstlaunch.com/submit", wait=6)
    s = snap()
    if 'textbox "e.g. Acme AI"' not in s:
        raise DriverFail("form not open at " + current_url() + ": " + say(text(200)))
    b("upload", "input[type=file][accept='image/png']", asset(site, "logo.png"))
    fill(s, r'textbox "e.g. Acme AI"', p["name"])
    fill(s, r'textbox "One sentence', fit(p["tagline"], 118))
    fill(s, r"textbox \"Tell people more", fit(p["long"], 990))
    cb = refs(s, r"combobox")
    b("select", "@" + cb[0], CAT[KIND[site]])
    b("select", "@" + cb[1], "Live — publicly available")
    fill(s, r'textbox "https://yoursite.com"', p["url"])
    b("upload", "input[type=file][multiple]", asset(site, "cover.png"))
    time.sleep(2)
    s = snap()
    ref = must(s, r'button "List my startup"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    url = current_url()
    page = text(1500)
    if "/submit" not in url or re.search(p["name"], page):
        return Result("live", f"{url.split('?')[0]}: public startup page '{p['name']}' LIVE")
    raise DriverFail("no confirmation: " + say(page, 300))
