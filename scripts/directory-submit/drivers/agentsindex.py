"""The Agents Index: free; prove ownership with a 6-digit code mailed to hello@<site domain> (routed to the owner mailbox), then Submit for review."""
import os
import re
import time
from lib import *

TARGET = "The Agents Index"
DELAY = 20
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]


def submit(site, p):
    host = p["url"].split("//")[1].rstrip("/")
    go("https://theagentsindex.com/submit", wait=6)
    fill(snap(), r'textbox "Your website"', p["url"])
    click(must(snap(), r'button "Check"'))
    time.sleep(8)
    q = '"Agents Index" newer_than:1d'
    before = mail_count(q)
    fill(snap(), r'textbox "Your email name at the site"', "hello")
    click(must(snap(), r'button "Send code"'))
    time.sleep(3)
    pin = mail_pin(q, r"\b(\d{6})\b", before, tries=20, delay=6)
    fill(snap(), r'textbox "The 6-digit code"', pin)
    click(must(snap(), r'button "Continue"'))
    time.sleep(5)
    s = snap()
    ref = must(s, r'button "Submit for review"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(5)
    page = text(2500)
    m = re.search(r"We.ll look at it within 2 days[^\n]*", page)
    if m:
        return Result("submitted", f"theagentsindex.com/submit: ownership code from hello@{host} accepted, Submit for review clicked: '{say(m.group(0), 120)}'")
    raise DriverFail("no confirmation: " + say(page[:500], 300))
