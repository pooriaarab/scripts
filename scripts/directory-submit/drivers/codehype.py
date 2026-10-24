"""CodeHype: free launch in the standard queue; account the maker mailbox (email confirm), logo and screenshot upload."""
import re
import time
from drivers.kit import values
from lib import *

TARGET = "CodeHype"
DELAY = 15
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]
CAT = {"agentsandboxes": "AI Agents", "agentwalletindex": "Finance"}


def submit(site, p):
    v = values(p)
    go("https://www.codehype.ai/submit", wait=5)
    ev("sessionStorage.clear(); Object.keys(localStorage).filter(k=>/draft|submit|launch|product/i.test(k)).forEach(k=>localStorage.removeItem(k))")
    go("https://www.codehype.ai/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if find(s, r'button "Login"'):
        raise DriverFail("signed out")
    fill(s, r'textbox "Product name', p["name"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 138))
    fill(s, r'textbox "Description', p["long"])
    fill(s, r'textbox "Website URL \*"', p["url"])
    select(0, CAT[site])
    click(must(snap(), r'button "Freemium"'))
    s = snap()
    click(must(s, r'button "Paid"')) if False else None
    ups = b("eval", "[...document.querySelectorAll('input[type=file]')].length")
    fr = refs(snap(), r'button "Choose File')
    if len(fr) < 2:
        raise DriverFail("upload buttons not found")
    b("upload", "@" + fr[0], asset(site, "logo.png"))
    b("upload", "@" + fr[1], asset(site, "cover.png"))
    time.sleep(3)
    fill(snap(), r'textbox "Problem It Solves', "People cannot easily compare options in this niche or find sourced facts in one place.")
    fill(snap(), r'textbox "Your Solution', "A directory with sourced listings, plus a free REST API and MCP server.")
    s = snap()
    ref = must(s, r'button "Launch your startup"')
    before = text(3000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    url = current_url()
    page = text(3000)
    m = re.search(r"(?i)[^\n]*(submitted|in review|pending|queue|scheduled|launched|success)[^\n]*", page)
    if m and m.group(0) not in before or "/submit" not in url:
        return Result("submitted", f"{url.split('?')[0]}: '{say(m.group(0) if m else page, 150)}'")
    raise DriverFail("no confirmation: " + say(page, 400))
