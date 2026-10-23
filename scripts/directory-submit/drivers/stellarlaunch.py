"""Stellar Launch: daily launch board. Email and password account (verified by a mailed link on the
first run), then a 4-step wizard. Only the Free Launch is chosen. Free launch days are spread
over the calendar (5 slots a day). The dashboard is the proof."""
import json
import time

from drivers.common import TOPIC, index
from lib import (DriverFail, Result, account, asset, b, click, current_url, ev, fill, final_click, fit, go, must, select,
                 snap, text, type_secret)

TARGET = "Stellar Launch"
DELAY = 12
RETRY_DAYS = 1
BASE = "https://www.stellarlaunch.org"
CATEGORY = {"dev": "Developer Tools", "finance": "Finance & FinTech", "social": "Online Forums",
            "health": "Health Tech", "education": "Platforms", "ecommerce": "E-commerce", "other": "Platforms"}


def login():
    go(BASE + "/dashboard", wait=5)
    if "/dashboard" in current_url():
        return
    email, pw = account("StellarLaunch")
    go(BASE + "/sign-in", wait=5)
    s = snap()
    fill(s, r'textbox "Email', email)
    type_secret(must(s, r'textbox "Password'), pw)
    click(must(snap(), r'button "Login"'))
    time.sleep(5)
    if "/dashboard" not in current_url():
        raise DriverFail("sign-in failed; make the account once with the sign-up page and verify the mailed link")


def listed(name):
    go(BASE + "/dashboard", wait=5)
    return ("\n" + name + "\n") in text(8000)


def submit(site, p):
    login()
    if listed(p["name"]):
        return Result("submitted", f"stellarlaunch.org dashboard already lists {p['name']}")
    go(BASE + "/projects/submit", wait=5)
    s = snap()
    fill(s, r'textbox "Project Name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 160))
    b("upload", "input[type=file]", asset(site, "logo.png"))
    time.sleep(3)
    ev("document.querySelector('[contenteditable=true]').focus()")
    b("keyboard", "inserttext", p["long"])
    time.sleep(1)
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    s = snap()
    click(must(s, r'checkbox "Directory"'))
    click(must(s, r'checkbox "' + CATEGORY[TOPIC[site]] + '"'))
    box = must(snap(), r'textbox "Tags')
    b("click", "@" + box)
    for tag in ("directory", "api", "mcp"):
        b("type", "@" + box, tag)
        b("press", "Enter")
        time.sleep(0.4)
    s = snap()
    click(must(s, r'checkbox "Web"'))
    click(must(snap(), r'radio "Free"'))
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    days = json.loads(ev("JSON.stringify([...document.querySelector('select').options].map(o=>o.value).filter(v=>v))"))
    day = days[3 + 2 * index(site)]
    select(0, day)
    time.sleep(1)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    if not final_click(must(snap(), r'button "Submit Project"')):
        return Result("skipped", "dry run")
    time.sleep(7)
    if listed(p["name"]):
        return Result("submitted", f"stellarlaunch.org dashboard (hello@beeloud.xyz) lists {p['name']}; free launch day {day} 8:00 UTC")
    return Result("blocked", "the dashboard does not list the project after submit")
