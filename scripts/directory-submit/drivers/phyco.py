"""Phyco Catalogue: free three-step form (same engine as ToolTrove), logo and screenshot required, reviewed by a person."""
import re
import time
from drivers.kit import KIND
from lib import *

TARGET = "Phyco Catalogue"
DELAY = 15
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Finance & Crypto", "health": "Health & Wellness", "education": "Education & Learning",
       "social": "Communication & Social", "transport": "Travel & Transport", "ecommerce": "Shopping & E-commerce",
       "realestate": "Home & Real Estate", "other": "Utilities & Converters"}
CAT_SITE = {"agentsandboxes": "AI & Automation", "agentwalletindex": "AI & Automation", "petcremation": "Home & Real Estate",
            "robotaxis": "Travel & Transport", "auctionfinder": "Shopping & E-commerce"}
FEATURES = "Search listings by place and category\nFree REST API and MCP server, no key needed\nSources cited on every listing"


def submit(site, p):
    go("https://phyco.org/submit", wait=6)
    dismiss_cookies()
    s = snap()
    fill(s, r'textbox "Website name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "(?:Your )?[Ee]mail', CONTACT_EMAIL)
    select_opt(CAT_SITE.get(site) or CAT[KIND[site]])
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    s = snap()
    fill(s, r'textbox "One-line description', fit(p["tagline"], 150))
    fill(s, r'textbox "Full description', p["long"])
    select_opt("Free")
    set_text("#features", FEATURES)
    for name in ("Web", "API"):
        b("check", "@" + must(snap(), rf'checkbox "{name}"'))
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    s = snap()
    ups = refs(s, r'button "(?:Logo|Screenshots)')
    if len(ups) < 2:
        raise DriverFail("media step not reached: " + say(ev("document.body.innerText.slice(300,900)")))
    b("upload", "@" + ups[0], asset(site, "logo.png"))
    b("upload", "@" + ups[1], asset(site, "cover.png"))
    time.sleep(2)
    s = snap()
    ref = must(s, r'button "(?:Submit for review|Submit)')
    q = "newer_than:1d from:phyco"
    mail_before = mail_count(q)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(5)
    link = html_link(q, r"(verify|confirm)", mail_before)
    go(link, wait=6)
    page = text(3000)
    m = re.search(r"(?i)[^\n]*(confirmed|review queue|thank)[^\n]*", page)
    if m:
        return Result("submitted", f"{current_url().split('?')[0]}: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page[:500], 300))
