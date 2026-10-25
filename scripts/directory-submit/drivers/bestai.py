"""Best-AI.org: free standard review; 5-step wizard; account the maker mailbox (Firebase email link, already signed in)."""
import re
import time
from lib import *

TARGET = "Best-AI.org"
DELAY = 10
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]


def tick(pat):
    s = snap()
    r_ = find(s, pat)
    if r_ and "checked=true" not in line(s, pat):
        b("check", "@" + r_)


def submit(site, p):
    go("https://best-ai.org/submit-tool", wait=6)
    try:
        click(must(snap(), r'button "Reject optional cookies'))
    except DriverFail:
        pass
    if find(snap(), r'button "Continue free submission"'):
        raise DriverFail("signed out")
    fill(snap(), r'textbox "Tool Website URL"', p["url"])
    click(must(snap(), r'button "Analyze my tool"'))
    for _ in range(10):
        time.sleep(3)
        if find(snap(), r'textbox "e\.g\., Awesome AI Writer"'):
            break
    fill(snap(), r'textbox "e\.g\., Awesome AI Writer"', p["name"])
    fill(snap(), r'textbox "Slogan', fit(p["tagline"], 140))
    fill(snap(), r'textbox "What does it do', fit(p["long"], 950))
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    for pat in (r'checkbox "AI Agents"', r'checkbox "Free"', r'radio "Open Access"', r'checkbox "Cloud"', r'checkbox "API Calls"'):
        tick(pat)
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    fill(snap(), r'textbox "Company', "example")
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    ref = must(snap(), r'button "Submit for Review"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(2500)
    m = re.search(r"Thank you for contributing![^\n]*", page)
    if m:
        return Result("submitted", f"best-ai.org/submit-tool: 'Thanks for submitting your tool! {say(m.group(0), 130)}'")
    raise DriverFail("no confirmation: " + say(page[:500], 300))
