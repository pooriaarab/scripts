"""Bidrise.live: free listing, live the moment you publish; account the maker mailbox."""
import re
import time
from drivers.kit import values
from lib import *

TARGET = "Bidrise.live"
DELAY = 8
RETRY_DAYS = 1


def submit(site, p):
    v = values(p)
    go("https://bidrise.live/app?list=free", wait=5)
    s = snap()
    if 'textbox "Project name"' not in s:
        for pat in (r'button "Free listing"', r'link "List free'):
            if find(s, pat):
                click(must(s, pat)); time.sleep(2); s = snap()
                break
    if 'textbox "Project name"' not in s:
        go("https://bidrise.live/?list=free", wait=5)
        s = snap()
        if find(s, r'button "Continue to add'):
            click(must(s, r'button "Continue to add')); time.sleep(4); s = snap()
    if 'textbox "Project name"' not in s:
        raise DriverFail("add-project form not open at " + current_url() + ": " + say(text(200)))
    fill(s, r'textbox "Project name"', p["name"])
    fill(s, r'textbox "Website"', p["url"].split("//")[1])
    fill(s, r'textbox "The one-line pitch"', fit(p["tagline"], 120))
    fill(s, r'textbox "Spotlight story', fit(p["short"], 400))
    click(must(s, r'checkbox "I accept the bid rules'))
    s = snap()
    ref = must(s, r'button "Publish project free"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(6000)
    host = p["url"].split("//")[1].rstrip("/")
    if re.search(re.escape(host), page) and re.search(re.escape(p["name"]), page):
        return Result("live", f"bidrise.live/app: '{p['name']} {host} Free' appears on the board")
    raise DriverFail("not on board: " + say(page, 300))
