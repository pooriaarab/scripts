"""AI Tool Seekers: free hand-reviewed listing; account the maker mailbox, logo and screenshot upload."""
import re
import time
from drivers.kit import values
from lib import *

TARGET = "AI Tool Seekers"
DELAY = 10
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]


def submit(site, p):
    v = values(p)
    go("https://aitoolseekers.com/submit", wait=6)
    s = snap()
    if "Sign in first" in s:
        raise DriverFail("not signed in")
    click(must(s, r'generic "AI Agent'))
    s = snap()
    fill(s, r'textbox "e.g. Lumina Write"', p["name"])
    fill(s, r'textbox "https://"', p["url"])
    fill(s, r"textbox \"A clear, keyword-rich", fit(p["tagline"], 150))
    fill(s, r'textbox "A few sentences', fit(p["long"], 990))
    cbs = refs(s, r"combobox")
    b("select", "@" + cbs[0], "Free")
    b("select", "@" + cbs[1], "AI Agents & Automation")
    b("select", "@" + cbs[-1], "Yes, this is my tool")
    ups = b("eval", "[...document.querySelectorAll('input[type=file]')].map(i=>i.id+':'+i.accept+':'+i.multiple).join(' ')")
    b("upload", "input[type=file]:not([multiple])", asset(site, "logo.png"))
    b("upload", "input[type=file][multiple]", asset(site, "cover.png"))
    time.sleep(2)
    s = snap()
    click(must(s, r'checkbox "I agree'))
    s = snap()
    ref = must(s, r'button "Submit for review"')
    if "disabled" in line(s, r'button "Submit for review"'):
        raise DriverFail("submit disabled; uploads: " + ups)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(7)
    page = text(2500)
    m = re.search(r"(?i)[^\n]*(thank|received|submitted|under review|we.ll review)[^\n]*", page)
    if m:
        return Result("submitted", f"aitoolseekers.com/submit: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page, 300))
