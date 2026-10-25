"""AI SuperHub: free listing (queue 90+ days), no login, email plus tool details."""
import re
import time
from drivers.kit import long_text
from lib import *

TARGET = "AI SuperHub"
DELAY = 15
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]
USE = {"agentsandboxes": "Compare cloud sandboxes for AI agents", "agentwalletindex": "Compare wallets and payment rails for AI agents"}


def submit(site, p):
    go("https://www.aisuperhub.io/ai-tools/submit/free", wait=7)
    s = snap()
    fill(s, r'textbox "Your Email"', CONTACT_EMAIL)
    fill(s, r'textbox "Tool Name"', p["name"])
    fill(s, r'textbox "Short description', " ".join(p["short"].split()[:28]))
    fill(s, r'textbox "Long description', long_text(p))
    fill(s, r'textbox "Primary Use Case"', USE[site])
    fill(s, r'textbox "Website URL"', p["url"])
    click(must(snap(), r'combobox "Category"'))
    time.sleep(1)
    click(must(snap(), r'option "Development"'))
    time.sleep(1)
    b("check", "@" + must(snap(), r'radio "No, not at this time"'))
    s = snap()
    ref = must(s, r'button "Submit for Review"')
    before = text(3000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(3000)
    new = [l for l in page.split("\n") if l.strip() and l not in before.split("\n")]
    m = re.search(r"(?i)[^\n]*(thank|submitted|received|success|review|queue)[^\n]*", "\n".join(new))
    if m:
        return Result("submitted", f"aisuperhub.io/ai-tools/submit/free: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page[:400], 250) + " | " + current_url())
