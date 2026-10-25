"""ToolTrove: free three-step form, no login; logo and a screenshot required; reviewed by a person."""
import re
import time
from drivers.kit import values
from lib import *

TARGET = "ToolTrove"
DELAY = 15
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]
CAT = {"agentsandboxes": "Code", "agentwalletindex": "Business"}
FEATURES = "Search listings by place and category\nFree REST API and MCP server, no key needed\nSources cited on every listing"


def submit(site, p):
    go("https://tooltrove.net/submit", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "Tool name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Your email', CONTACT_EMAIL)
    b("select", "@" + refs(s, "combobox")[0], CAT[site])
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    s = snap()
    fill(s, r'textbox "One-line description', fit(p["tagline"], 150))
    fill(s, r'textbox "Full description', p["long"])
    b("select", "@" + refs(s, "combobox")[0], "Free")
    set_text("#features", FEATURES)
    for name in ("Web", "API"):
        b("check", "@" + must(snap(), rf'checkbox "{name}"'))
    if not ev("[...document.querySelectorAll('input[type=checkbox]')].slice(0,1).every(c=>c.checked)"):
        raise DriverFail("platform checkbox did not take")
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    s = snap()
    ups = refs(s, r'button "(?:Logo|Screenshots)')
    if len(ups) < 2:
        raise DriverFail("media step not reached: " + say(text(300)))
    b("upload", "@" + ups[0], asset(site, "logo.png"))
    b("upload", "@" + ups[1], asset(site, "cover.png"))
    time.sleep(2)
    s = snap()
    ref = must(s, r'button "Submit for review"')
    q = f"newer_than:1d from:tooltrove subject:Confirm"
    mail_before = mail_count(q)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(5)
    link = html_link(q, r"submit/verify", mail_before)
    go(link, wait=6)
    before = ""
    page = text(3000)
    m = re.search(r"(?i)[^\n]*(Submission confirmed|review queue)[^\n]*", page)
    if m and m.group(0) not in before:
        return Result("submitted", f"tooltrove.net/submit/verify: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page[:600], 400))
