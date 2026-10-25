"""Minimal Gallery: a selective design gallery with a free form. Two sites with a plain,
type-led layout are filed. Most submissions are refused; the review takes 1-2 weeks."""
import time

from lib import (CONTACT_EMAIL, DriverFail, Result, b, click, current_url, fill, final_click, go, must, refs, say, setting,
                 snap, text)

TARGET = "Minimal Gallery"
SITES = ["foreclosurelistings", "french4pr"]
DELAY = 10
RETRY_DAYS = 1


def submit(site, p):
    go("https://minimal.gallery/submit/", wait=6)
    click(must(snap(), r'button "Website Submit'))  # step 1 opens the form
    time.sleep(2)
    s = snap()
    boxes = refs(s, r'textbox \[required')
    if len(boxes) != 4:
        raise DriverFail(f"expected 4 required fields, found {len(boxes)}")
    for ref, value in zip(boxes, (p["url"], p["name"], setting("DIRSUB_MAKER_NAME"), CONTACT_EMAIL)):
        b("fill", "@" + ref, value)
    fill(s, r'textbox "Message \(optional', p["tagline"] + " " + p["short"])
    s = snap()
    if not final_click(must(s, r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    if "submit-thanks" in current_url():
        return Result("submitted", "minimal.gallery/submit-thanks: 'Your submission was received.' (an email follows if it is published; review 1-2 weeks)")
    return Result("blocked", "no thank-you page after submit: " + say(text(300)))
