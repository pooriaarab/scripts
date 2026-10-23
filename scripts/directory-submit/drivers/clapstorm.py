"""Clapstorm: a free launch page that goes live on the weekly board.
The board allows 3 launches per week per account."""
import re
import time

from lib import (DriverFail, RateLimited, Result, asset, b, category, current_url, fill, final_click, fit,
                 go, must, snap, text, wait_ref)

TARGET = "Clapstorm"
DELAY = 10
RETRY_DAYS = 7


def submit(site, p):
    go("https://www.clapstorm.com/submit")
    _, s = wait_ref(r'textbox "URL')
    fill(s, r'textbox "URL', p["url"])
    fill(s, r'textbox "NAME', p["name"])
    fill(s, r'textbox "TAGLINE', fit(p["tagline"], 100))
    fill(s, r'textbox "DESCRIPTION', p["long"])
    chosen = category(p, "clapstorm", "")
    if chosen:
        b("select", "@" + must(s, r'combobox "CATEGORY'), chosen)
    b("upload", "input[type=file]", asset(site, "logo.png"))
    time.sleep(3)
    if not final_click(must(snap(), r'button "Launch it')):
        return Result("skipped", "dry run")
    time.sleep(7)
    url = current_url()
    if "/p/" in url:
        return Result("submitted", f"{url} (live on the weekly board)")
    page = text(500, 150)
    if re.search(r"(?i)limit|per week|too many", page):
        raise RateLimited("3 launches per week per account")
    raise DriverFail(f"{url} {page}")
