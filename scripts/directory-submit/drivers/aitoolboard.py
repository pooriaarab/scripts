"""AI Tool Board: free listing (pending approval); account the maker mailbox; tool image required."""
import re
import time
from lib import *

TARGET = "AI Tool Board"
DELAY = 15
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]


def submit(site, p):
    go("https://aitoolboard.com/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if find(s, r'button "Sign In"') and not find(s, r'textbox "e.g., ChatGPT"'):
        raise DriverFail("signed out")
    fill(s, r'textbox "e.g., ChatGPT"', p["name"])
    fill(s, r'textbox "Brief description', fit(p["tagline"], 140))
    fill(s, r'textbox "Detailed description', p["long"])
    fill(s, r'textbox "http://example.com', p["url"])
    cat = ev("[...[...document.querySelectorAll('select')][0].options].map(o=>o.text).find(t=>/Automation/.test(t))")
    select(0, cat)
    fill(snap(), r'textbox "AI, chatbot', "agents, developer tools, api")
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    s = snap()
    if not re.search(r'radio "Free Listing[^\]]*checked=true', s):
        raise DriverFail("Free Listing not selected")
    ref = must(s, r'button "Submit Tool"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    go("https://aitoolboard.com/my-account", wait=5)
    page = text(2500)
    m = re.search(r"My Tools\s*\n?\s*(\d+)", page)
    if m and int(m.group(1)) > (1 if site == "agentwalletindex" else 0):
        return Result("submitted", f"aitoolboard.com/my-account: 'My Tools {m.group(1)}' after the Free Listing (pending approval) submit of {p['name']}")
    raise DriverFail("My Tools did not rise: " + say(page[:300], 200))
