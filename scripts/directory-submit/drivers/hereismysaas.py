"""HereIsMySaaS: free hand-reviewed listing; account the maker mailbox (email+password, no email check seen)."""
import re
import time
from lib import *

TARGET = "HereIsMySaaS"
DELAY = 8
RETRY_DAYS = 1


def submit(site, p):
    go("https://hereismysaas.com/submit", wait=5)
    dismiss_cookies()
    s = snap()
    if not find(s, r'textbox "https://your-saas'):
        raise DriverFail("form not open at " + current_url())
    fill(s, r'textbox "https://your-saas', p["url"])
    fill(s, r'textbox "e.g. Notion', p["name"])
    fill(s, r'textbox "What does your SaaS', fit(p["tagline"], 78))
    click(must(snap(), r'button "Select a category"'))
    time.sleep(1)
    click(must(snap(), r'button "Directory"'))
    time.sleep(1)
    s = snap()
    ref = must(s, r'button "Submit for review"')
    if "disabled" in line(s, r'button "Submit for review"'):
        raise DriverFail("submit disabled")
    before = text(3000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(3000)
    if "already listed or pending review" in page:
        return Result("submitted", "hereismysaas.com/submit: 'This website is already listed or pending review.'")
    if current_url().rstrip("/") == "https://hereismysaas.com":
        s2 = go("https://hereismysaas.com/submit", wait=4)
        s2 = snap()
        fill(s2, r'textbox "https://your-saas', p["url"])
        fill(s2, r'textbox "e.g. Notion', p["name"])
        fill(s2, r'textbox "What does your SaaS', fit(p["tagline"], 78))
        click(must(snap(), r'button "Select a category"'))
        time.sleep(1)
        click(must(snap(), r'button "Directory"'))
        time.sleep(1)
        click(must(snap(), r'button "Submit for review"'))
        time.sleep(2)
        if "already listed or pending review" in text(3000):
            return Result("submitted", "hereismysaas.com/submit: submit redirected to home; resubmitting answers 'This website is already listed or pending review.'")
    new = [l for l in page.split("\n") if l.strip() and l not in before.split("\n")]
    m = re.search(r"(?i)[^\n]*(submitted|thank|received|review|success|pending)[^\n]*", "\n".join(new))
    if m:
        return Result("submitted", f"hereismysaas.com/submit: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page, 300) + " | url " + current_url())
