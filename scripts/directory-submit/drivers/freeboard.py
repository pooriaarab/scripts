"""Freeboard: free verified-email route (6-digit code, then manual review). Never click the $10 button."""
import re
import time
from lib import *

TARGET = "Freeboard"
DELAY = 20
RETRY_DAYS = 1


def submit(site, p):
    go("https://freeboard.lol/submit", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "yoursite.com"', p["url"])
    fill(s, r'textbox "Your site.s name"', p["name"])
    fill(s, r'textbox "What it is, one line"', fit(p["tagline"], 110))
    select_opt("Websites & Directories")
    fill(snap(), r'textbox "you@company.com"', CONTACT_EMAIL)
    q = "newer_than:1d freeboard"
    before = mail_count(q)
    click(must(snap(), r'button "Send verification code"'))
    time.sleep(4)
    page = text(3000)
    if re.search(r"(?i)too many|rate limit|already", page) and not find(snap(), r'textbox "000000"'):
        raise RateLimited(say(page[:200], 150))
    for _ in range(20):
        if mail_count(q) > before:
            break
        time.sleep(6)
    else:
        raise DriverFail("no verification mail")
    m = re.search(r"\b(\d{6})\b", newest_message(q))
    if not m:
        raise DriverFail("no code in mail")
    fill(snap(), r'textbox "000000"', m.group(1))
    click(must(snap(), r'button "Confirm code"'))
    time.sleep(5)
    page = text(4000)
    mm = re.search(r"Email confirmed\.[^\n]*", page)
    if mm:
        return Result("submitted", f"freeboard.lol/submit: '{say(mm.group(0), 140)}'")
    raise DriverFail("no confirmation: " + say(page[-500:], 300))
