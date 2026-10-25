"""llmslist.com: anonymous form for a site with an llms.txt. Every fleet site serves /llms.txt and
/llms-full.txt. The board stops at about 10 submissions in 10 minutes from one network."""
import time

from drivers.common import TOPIC
from lib import (CONTACT_EMAIL, RateLimited, Result, fill, final_click, fit, go, must, say, select, snap, text)

TARGET = "llmslist.com"
DELAY = 45
RETRY_DAYS = 1
CATEGORY = {"dev": "Developer Tools", "finance": "Finance", "education": "Education", "health": "Other",
            "social": "Other", "ecommerce": "Other", "other": "Other"}


def submit(site, p):
    go("https://llmslist.com/submit", wait=4)
    s = snap()
    fill(s, r'textbox "Site name', p["name"])
    fill(s, r'textbox "Site URL', p["url"])
    fill(s, r'textbox "llms.txt URL', p["url"] + "/llms.txt")
    fill(s, r'textbox "llms-full.txt', p["url"] + "/llms-full.txt")
    fill(s, r'textbox "Short description', fit(p["short"], 200))
    fill(s, r'textbox "Your email', CONTACT_EMAIL)
    select(0, CATEGORY[TOPIC[site]])
    select(1, "Search engine")
    time.sleep(1)
    if not final_click(must(snap(), r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(5)
    page = text(1500)
    if "Submission received" in page:
        return Result("submitted", "llmslist.com/submit: 'Submission received. It will be added to the directory after review.'")
    if "Too many requests" in page:
        raise RateLimited("'Too many requests. Please try again later.'")
    return Result("blocked", "no confirmation after submit: " + say(page, 150))
