"""FridayHunt, and any board built on the same template (see shipycorn.py): weekly Friday launch board. Magic-link sign-in with the contact email, then a
4-step wizard. Only the Free Launch is chosen; the Premium upsell modal is closed, never accepted.
Launch weeks are spread over the weeks the board offers (6 free slots a week)."""
import time

from drivers.common import TOPIC, index
from lib import (CONTACT_EMAIL, DriverFail, Result, asset, b, click, current_url, ev, fill, final_click, find, fit, go,
                 mail_count, mail_link, must, select, setting, snap, text)

TARGET = "FridayHunt"
DELAY = 12
RETRY_DAYS = 1
CATEGORY = {"dev": "Developer Tools", "finance": "Finance & Payments", "social": "Social & Community",
            "health": "Health & Fitness", "education": "Education", "ecommerce": "E-Commerce", "other": "Productivity"}


def login(base, sender):
    go(f"{base}/dashboard", wait=5)
    if "/dashboard" in current_url():
        return
    before = mail_count(f"from:{sender} newer_than:1d")
    go(f"{base}/sign-in", wait=5)
    s = snap()
    fill(s, r'textbox "you@example', CONTACT_EMAIL)
    click(must(s, r'checkbox "I agree'))
    click(must(snap(), r'button "Send magic link'))
    go(mail_link(f"from:{sender} newer_than:1d", r"magic-link/verify", before), wait=6)
    if "/onboarding" in current_url():
        fill(snap(), r'textbox "Name', setting("DIRSUB_MAKER_NAME"))
        click(must(snap(), r'button "Continue"'))
        time.sleep(4)
    if "/dashboard" not in current_url():
        raise DriverFail("sign-in did not reach the dashboard")


def listed(base, name):
    """Status text next to the project name on the dashboard, or None. The dashboard is the proof:
    the submit page can end in a server error after the project was created."""
    go(f"{base}/dashboard", wait=5)
    page = text(6000)
    i = page.find("\n" + name + "\n")
    return page[i + 1:].split("\n")[1].strip() if i >= 0 else None


def launch(site, p, base, sender):
    login(base, sender)
    if listed(base, p["name"]):
        return Result("submitted", f"{base.split('//')[1]} dashboard already lists {p['name']}")
    go(f"{base}/projects/submit", wait=5)
    s = snap()
    fill(s, r'textbox "Project Name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Short Description', fit(p["short"], 160))
    b("upload", "input[type=file]", asset(site, "logo.png"))
    time.sleep(3)
    ev("document.querySelector('.ProseMirror').focus()")
    b("keyboard", "inserttext", p["long"])
    time.sleep(1)
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    s = snap()
    click(must(s, r'checkbox "' + CATEGORY[TOPIC[site]] + '"'))
    click(must(s, r'checkbox "Web"'))
    click(must(s, r'radio "Free"'))
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    click(must(snap(), r'heading "Free Launch"'))
    weeks = ev("JSON.stringify([...document.querySelector('select').options].map(o=>o.value).filter(v=>v))")
    import json
    if not weeks:
        raise DriverFail("no launch weeks on step 3")
    weeks = json.loads(weeks)
    select(0, weeks[index(site) % len(weeks)])
    time.sleep(1)
    close = find(snap(), r'button "Close"')
    if close:  # the Premium upsell modal
        click(close)
        time.sleep(1)
    click(must(snap(), r'button "Next"'))
    time.sleep(2)
    click(must(snap(), r'checkbox "I agree to the launch voting policy'))
    s = snap()
    if not final_click(must(s, r'button "Submit Project"')):
        return Result("skipped", "dry run")
    time.sleep(7)
    status = listed(base, p["name"])
    if status:
        return Result("submitted", f"{base.split('//')[1]} dashboard (hello@example.xyz): '{p['name']} {status}'; free launch week {weeks[index(site) % len(weeks)]}")
    return Result("blocked", "the dashboard does not list the project after submit")


def submit(site, p):
    return launch(site, p, "https://fridayhunt.com", "fridayhunt")
