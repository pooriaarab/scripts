"""AgentSquare: free vendor listing; account the maker mailbox (email confirm, profile name and about); save a draft then Publish."""
import re
import time
from lib import *

TARGET = "AgentSquare"
DELAY = 10
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]


def submit(site, p):
    go("https://agentsquare.io/my-agents?new=1", wait=6)
    s = snap()
    if not find(s, r'textbox "e\.g\., Marketing Expert"'):
        raise DriverFail("form not open: " + say(text(200)))
    fill(s, r'textbox "e\.g\., Marketing Expert"', p["name"])
    fill(snap(), r'textbox "Describe what your product', p["long"])
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    select_opt("Agent Builders & Platforms")
    time.sleep(1)
    ref = must(snap(), r'button "Save"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    row = ev("document.body.innerText")
    pub = find(snap(), r'button "Publish"')
    # publish the row for this product
    js = ("(()=>{const rows=[...document.querySelectorAll('tr')];const r=rows.find(r=>r.innerText.includes(%s)&&/Draft/.test(r.innerText));"
          "if(!r)return 'NO-ROW';const b=[...r.querySelectorAll('button')].find(b=>/Publish/.test(b.innerText));if(!b)return 'NO-BTN';b.click();return 'OK'})()") % repr(p["name"]).replace("'", '"')
    if "OK" not in str(ev(js)):
        raise DriverFail("no Draft row to publish for " + p["name"])
    time.sleep(5)
    page = ev("document.body.innerText")
    if re.search(re.escape(p["name"]) + r"[\s\S]{0,300}Published", str(page)):
        return Result("submitted", f"agentsquare.io/my-agents: '{p['name']}' Status Published after Publish (public listing URL not found)")
    raise DriverFail("not published: " + say(str(page)[:300], 200))
