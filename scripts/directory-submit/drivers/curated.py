"""Curated.design: a design gallery with a free review queue ($29 priority is never chosen).
A gallery judges design, so one site per visual preset is filed, not all 17."""
import time

from lib import (CONTACT_EMAIL, RateLimited, Result, click, fill, final_click, fit, go, must, say, select, snap, text)

TARGET = "Curated.design"
SITES = ["foreclosurelistings", "agentsandboxes", "agentwalletindex", "robotaxis", "datingcoaches", "doulas",
         "fertilityclinics", "psilocybincenters"]
DELAY = 8
RETRY_DAYS = 1
CATEGORY = {"foreclosurelistings": "Web Apps", "agentsandboxes": "Development Tools", "agentwalletindex": "Finance",
            "robotaxis": "Tech", "datingcoaches": "Web Apps", "doulas": "Web Apps", "fertilityclinics": "Web Apps",
            "psilocybincenters": "Web Apps"}


def submit(site, p):
    go("https://curated.design/submit/", wait=6)
    s = snap()
    fill(s, r'textbox "Site name', p["name"])
    fill(s, r'textbox "Site URL', p["url"])
    fill(s, r'textbox "Your email', CONTACT_EMAIL)
    fill(s, r'textbox "Tagline', p["tagline"])
    fill(s, r'textbox "What makes it worth', fit(p["short"], 240))
    select(0, CATEGORY[site])
    click(must(s, r'radio "Free queue'))
    s = snap()
    ref = must(s, r'button "Join the free queue')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(900)
    if "it's in the queue" in page:
        return Result("submitted", "curated.design/submit: \"Thanks, it's in the queue.\" (free queue, a person reads each entry, a few weeks)")
    if "Send the rest tomorrow" in page:
        raise RateLimited("5 sites a day; 'That is a lot of sites for one day. Send the rest tomorrow.'")
    return Result("blocked", "no confirmation after submit: " + say(page))
