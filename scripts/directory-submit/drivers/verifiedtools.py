"""Verified Tools Directory: free plan (7-9 week queue), no account; plan radio defaults to the paid Starter, so tick Free."""
import re
import time
from drivers.kit import KIND
from lib import *

TARGET = "Verified Tools Directory"
DELAY = 10
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Finance", "health": "Healthcare", "education": "Education",
       "social": "Other", "transport": "Other", "ecommerce": "Other", "realestate": "Finance", "other": "Other"}
CAT_SITE = {"agentsandboxes": "AI Assistants", "agentwalletindex": "Finance"}


def submit(site, p):
    go("https://verifiedtools.info/submit", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "My Awesome Tool"', p["name"])
    fill(s, r'textbox "my-awesome-tool"', slug(p["name"]))
    fill(s, r'textbox "https://example.com"', p["url"])
    fill(s, r'textbox "Short catchy', fit(p["tagline"], 100))
    fill(s, r'textbox "Brief description', fit(p["short"], 155))
    fill(s, r'textbox "Detailed description', fit(p["long"], 990))
    fill(s, r'textbox "contact@example.com"', CONTACT_EMAIL)
    select_opt(CAT_SITE.get(site) or CAT[KIND[site]])
    select_opt("Free")
    b("check", "@" + must(snap(), r'radio "Free \$0'))
    ups = refs(snap(), r'button "Choose File')
    if len(ups) < 2:
        raise DriverFail("upload buttons not found")
    b("upload", "@" + ups[0], asset(site, "logo.png"))
    time.sleep(2)
    b("upload", "@" + ups[1], asset(site, "cover.png"))
    time.sleep(2)
    s = snap()
    if not re.search(r'radio "Free \$0[^\]]*checked=true', s):
        raise DriverFail("Free plan is not the selected plan; not submitting")
    ref = must(s, r'button "Submit"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(3000)
    m = re.search(r"Submission received![^\n]*\n?[^\n]*", page)
    if m:
        return Result("submitted", f"verifiedtools.info/submit: '{say(m.group(0), 140)}'")
    raise DriverFail("no confirmation: " + say(page, 300))
