"""LaunchRanked: free launch, followed link, no badge; account the maker mailbox via emailed sign-in link."""
import re
import time
from lib import *

TARGET = "LaunchRanked"
DELAY = 10
RETRY_DAYS = 1
CAT_SITE = {"agentsandboxes": "AI tools", "agentwalletindex": "AI tools", "creditunions": "Finance", "foreclosurelistings": "Finance",
            "drivingschool": "Education", "french4pr": "Education", "immigrationhelp": "Education", "auctionfinder": "Ecommerce"}


def submit(site, p):
    go("https://launchranked.com/launch", wait=6)
    dismiss_cookies()
    s = snap()
    if not find(s, r'button "Submit launch"') and not find(snap(), r'button "Account menu'):
        raise DriverFail("signed out")
    fill(s, r'textbox "Website"', p["url"])
    fill(s, r'textbox "Product name"', p["name"])
    fill(s, r'textbox "Tagline"', fit(p["tagline"], 78))
    fill(s, r'textbox "Description"', p["long"])
    select_opt(CAT_SITE.get(site, "Other"))
    for pat in (r'radio "Free"', r'radio "Free Free Get listed', r'radio "Not now'):
        b("check", "@" + must(snap(), pat))
    set_text("input[name=maker_name]", "Pooria Arab")
    for _ in range(6):
        rm = refs(snap(), r'button "Remove')
        if not rm:
            break
        b("click", "@" + rm[0])
        time.sleep(1)
    ups = refs(snap(), r'button "Choose (?:a logo|screenshots)')
    if len(ups) < 2:
        raise DriverFail("upload buttons not found")
    b("upload", "@" + ups[0], asset(site, "logo.png"))
    time.sleep(3)
    b("upload", "@" + ups[1], asset(site, "cover.png"))
    time.sleep(3)
    s = snap()
    if not re.search(r'radio "Free Free Get listed[^\]]*checked=true', s):
        raise DriverFail("Free plan not selected")
    ref = must(s, r'button "Submit launch"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(9)
    url = current_url()
    page = text(1500)
    if "/launch/success" in url and "SUBMITTED" in page:
        m = re.search(r"Scheduled for[^\n]*", page)
        return Result("submitted", f"{url.split('&code')[0]}: 'SUBMITTED. {say(m.group(0) if m else '', 110)}'")
    raise DriverFail("no confirmation at " + url + ": " + say(page, 300))
