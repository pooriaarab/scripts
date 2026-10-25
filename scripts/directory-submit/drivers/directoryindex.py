"""Directory Index: free web directory, no account; homepage URL only, SEO content text, category, email."""
import json
import re
import time
from drivers.kit import values, KIND
from lib import *

TARGET = "Directory Index (free dofollow web directory)"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": "Technology & Software", "finance": "Business & Finance", "health": "Health & Wellness",
       "education": "Education", "social": "Society", "transport": "Travel & Tourism", "ecommerce": "Shopping",
       "realestate": "Home & Real Estate", "other": "Services"}


def submit(site, p):
    go("https://directory-index.com/", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "WEBSITE URL', p["url"])
    fill(s, r'textbox "WEBSITE NAME', p["name"])
    fill(s, r'textbox "DESCRIPTION', fit(p["short"], 300))
    fill(s, r'textbox "SEO CONTENT', p["long"])
    fill(s, r'textbox "EMAIL', CONTACT_EMAIL)
    b("upload", "#image", asset(site, "cover.png"))
    opt = ev("[...document.querySelectorAll('select')[0].options].map(o=>o.text).find(t=>t.includes(%s))" % json.dumps(CAT[KIND[site]]))
    b("select", "@" + refs(s, "combobox")[0], opt)
    s = snap()
    ref = must(s, r'button "Submit to Directory')
    before = text(4000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(7)
    page = text(4000)
    url = current_url()
    for _ in range(14):
        if re.search(r"Live now|rejected|duplicate listing found|could not", page):
            break
        time.sleep(10)
        page = text(4000)
        url = current_url()
    if "confirm.php" in url and re.search(r"Live now", page):
        return Result("live", f"{url}: '{p['name']} {p['url'].split('//')[1]} Live now'")
    if "confirm.php" in url and re.search(r"(?i)rejected|duplicate|could not|failed", page):
        raise DriverFail("board said: " + say(page, 300))
    new = [l for l in page.split("\n") if l.strip() and l not in before.split("\n")]
    if re.search(r"error=", url):
        raise DriverFail("board refused: " + url.split("?")[1][:120])
    m = re.search(r"(?i)(thank you|successfully|has been submitted|is now live|success=)", " ".join(new) + " " + url)
    if m:
        return Result("submitted", f"directory-index.com: '{say(' '.join(new), 150)}'")
    raise DriverFail("no confirmation: " + say(page, 300))
