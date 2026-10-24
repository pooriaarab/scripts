"""MAQTOOB: business software directory; account the maker mailbox, logo upload, reviewed before publishing."""
import re
import time
from drivers.kit import values
from lib import *

TARGET = "MAQTOOB (SaaS directory)"
DELAY = 10
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]
CAT = {"agentsandboxes": "Business Automation Tools", "agentwalletindex": "Business Intelligence and Analytics Software"}


def submit(site, p):
    v = values(p)
    go("https://maqtoob.com/software-submit-page/", wait=6)
    s = snap()
    if "No file chosen" not in s and 'textbox "Tool Name' not in s:
        raise DriverFail("not logged in: " + say(text(200)))
    fill(s, r'textbox "Tool Name', p["name"])
    fill(s, r'textbox "Subtitle', fit(p["tagline"], 90))
    fill(s, r'textbox "Tool Description', p["long"])
    fill(s, r'textbox "Website URL', p["url"])
    b("upload", "input[type=file]", asset(site, "logo.png"))
    fill(s, r'textbox "Key Features', v["features_line"])
    fill(s, r'textbox "Pricing', "Free")
    click(must(s, r'LabelText "' + CAT[site] + '"'))
    time.sleep(1)
    s = snap()
    ref = must(s, r'button "Submit Tool for Review"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(1500)
    if re.search(r"(?i)thank|submitted|review|success", page) and "required" not in page.lower()[:200]:
        return Result("submitted", f"maqtoob.com: '{say(page, 140)}'")
    raise DriverFail("no confirmation: " + say(page, 250))
