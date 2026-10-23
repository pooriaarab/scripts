"""HuntScreens: magic-link sign-in with the contact email, then a one-field free queue submit
(about 30 days, nofollow). The VIP and paid packages are never chosen."""
import time

from lib import (CONTACT_EMAIL, DriverFail, Result, click, current_url, fill, final_click, find, go, mail_count, mail_link,
                 must, say, snap, text)

TARGET = "Huntscreens"
DELAY = 8
RETRY_DAYS = 1
QUERY = "from:huntscreens newer_than:1d"


def login():
    go("https://huntscreens.com/submit", wait=5)
    if find(snap(), r'button "User menu"'):
        return
    before = mail_count(QUERY)
    click(must(snap(), r'button "Log in"'))
    time.sleep(2)
    fill(snap(), r'textbox "Email address"', CONTACT_EMAIL)
    click(must(snap(), r'button "Continue with Email"'))
    go(mail_link(QUERY, r"magic-link/verify", before), wait=6)
    if not find(snap(), r'button "User menu"'):
        raise DriverFail("not signed in after the magic link")


def submit(site, p):
    login()
    go("https://huntscreens.com/submit", wait=5)
    click(must(snap(), r'button "Queue Zero cost'))
    time.sleep(1)
    fill(snap(), r'textbox "https://your-product.com"', p["url"])
    time.sleep(1)
    if not final_click(must(snap(), r'button "Submit for Free"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    url = current_url()
    if "/submit/success" in url:
        return Result("submitted", "huntscreens.com/submit/success: 'Submission Queued', Free Queue (about 30 days review, nofollow link)")
    return Result("blocked", "no success page after submit: " + say(text(900), 150))
