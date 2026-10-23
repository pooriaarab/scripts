"""SaaSRow (Profullstack network): the free tier takes one URL a submission, no account.
The board reads the page metadata, then asks for an email that gets a management link.
The newsletter box stays unchecked. The free listing lasts 90 days."""
import time

from lib import (CONTACT_EMAIL, Result, click, fill, final_click, find, go, mail_count, must, snap, text, wait_ref)

TARGET = "SaaSRow"
DELAY = 10
RETRY_DAYS = 1


def submit(site, p):
    before = mail_count("from:saasrow newer_than:1d")
    go("https://saasrow.com/submit", wait=5)
    start_over = find(snap(), r'button "Start Over"')  # the page keeps an earlier draft
    if start_over:
        click(start_over)
        time.sleep(2)
    fill(snap(), r'textbox "Software URL', p["url"])
    click(must(snap(), r'button "Continue"'))
    time.sleep(8)
    if "This domain has already been submitted" in text(3000):
        return Result("submitted", "saasrow.com/submit: 'This domain has already been submitted' (the destination's own duplicate check; the earlier management email says it is being reviewed)")
    click(wait_ref(r'button "Submit All')[0])
    time.sleep(3)
    fill(snap(), r'textbox "your@email.com', CONTACT_EMAIL)
    if not final_click(must(snap(), r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    # The page returns to the empty form. The management email is the confirmation; its count goes up.
    # Never raise after the final click: a retry would file the site twice.
    for _ in range(10):
        if mail_count("from:saasrow newer_than:1d") > before:
            return Result("submitted", "saasrow.com: email 'Manage Your SaaSRow Listings' to hello@example.xyz says the submission is being reviewed (free tier, 90 days)")
        time.sleep(6)
    return Result("blocked", "no management email after submit")
