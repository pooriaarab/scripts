"""Favors.dev: free listing, two-week review; account the maker mailbox (emailed confirm link). Never buy an add-on."""
import re
import time
from lib import *

TARGET = "Favors.dev"
DELAY = 12
RETRY_DAYS = 1


def submit(site, p):
    go("https://favors.dev/projects/new", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "Start with your website"', p["url"])
    fill(s, r'textbox "Name"', p["name"])
    fill(s, r'textbox "Tagline"', fit(p["tagline"], 100))
    fill(s, r'textbox "About', p["long"])
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "cover.png"))
    time.sleep(3)
    click(must(snap(), r'button "Category"'))
    time.sleep(1)
    click(must(snap(), r'option "Web Apps"'))
    time.sleep(1)
    ref = must(snap(), r'button "(?:Publish my project|Create project)"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(9)
    page = text(2500)
    url = current_url()
    m = re.search(re.escape(p["name"]) + r" is in\.", page)
    n = re.search(r"Live on [A-Z][a-z]+ \d+", page)
    if m and "/upgrade" in url:
        return Result("submitted", f"{url.split('?')[0].replace('https://', '')}: '{m.group(0)} Listing saved. In review. {n.group(0) if n else ''}'")
    raise DriverFail("no confirmation at " + url + ": " + say(page, 300))
