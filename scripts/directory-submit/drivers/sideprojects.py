"""Sideprojects.net: email and password account (made on the first run), then a launch form.
A free launch joins the review queue with no date. The free launch has a dofollow backlink."""
import time

from drivers.common import TOPIC
from lib import (DriverFail, Result, account, click, current_url, fill, final_click, fit, go, must, say, snap, text,
                 type_secret)

TARGET = "Sideprojects.net"
DELAY = 10
RETRY_DAYS = 1
CATEGORIES = {"dev": ["AI", "Developer tools"], "finance": ["Productivity"], "social": ["Community"],
              "health": ["Health"], "education": ["Productivity"], "ecommerce": ["Productivity"],
              "other": ["Productivity"]}


def login():
    go("https://sideprojects.net/projects/submit", wait=5)
    if "/projects/submit" in current_url():
        return
    email, pw = account("Sideprojects")
    s = snap()
    fill(s, r'textbox "Email', email)
    type_secret(must(s, r'textbox "Password'), pw)
    click(must(snap(), r'button "Log in"'))
    time.sleep(5)
    go("https://sideprojects.net/projects/submit", wait=5)
    if "/projects/submit" not in current_url():
        raise DriverFail("not signed in")


def submit(site, p):
    login()
    s = snap()
    fill(s, r'textbox "Project URL', p["url"])
    fill(s, r'textbox "Name', p["name"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 120))
    fill(s, r'textbox "About', p["long"])
    for c in CATEGORIES[TOPIC[site]]:
        click(must(snap(), r'checkbox "' + c + '"'))
    s = snap()
    if not final_click(must(s, r'button "Submit for launch"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    url = current_url()
    if "/projects/submit" not in url:
        return Result("submitted", f"{url.split('//')[1]} (free launch queue, account hello@beeloud.xyz)")
    page = text(1500)
    if "That launch date is full" in page:
        return Result("blocked", "'That launch date is full — pick another.' and the launch-date list is empty, so no free launch day is open")
    return Result("blocked", "still on the form after submit: " + say(page[-300:], 150))
