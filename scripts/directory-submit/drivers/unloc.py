"""Unloc Tools: a free form behind a managed Turnstile that passes in the owner's Chrome.
The board limits submissions per network. Do not rotate networks."""
import time

from lib import (CONTACT_EMAIL, DriverFail, RateLimited, Result, b, category, click, current_url, fill,
                 final_click, find, fit, go, must, setting, snap, text)

TARGET = "Unloc Tools"
DELAY = 10
RETRY_DAYS = 1
DEFAULT_CATEGORY = "Productivity & Notes"


def submit(site, p):
    go("https://unloc.tools/submit")
    s = snap()
    reject = find(s, r'button "Reject all"')
    if reject:
        click(reject)
        time.sleep(1)
        s = snap()
    fill(s, r'textbox "Tool name', p["name"])
    fill(s, r'textbox "Website', p["url"])
    fill(s, r'textbox "Tool description', fit(p["short"], 160))
    b("select", "@" + must(s, r'combobox "Category'), category(p, "unloc", DEFAULT_CATEGORY))
    b("select", "@" + must(s, r'combobox "Pricing'), "Free")
    fill(s, r'textbox "Full name', setting("DIRSUB_MAKER_NAME"))
    fill(s, r'textbox "Email', CONTACT_EMAIL)
    for _ in range(10):  # wait for the Turnstile token
        got = b("eval", "(document.querySelector('[name=cf-turnstile-response]')||{}).value ? 'token-present' : 'no-token'")
        if "token-present" in got:
            break
        time.sleep(3)
    if not final_click(must(snap(), r'button "Submit for review"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    if "submit/thanks" in current_url():
        return Result("submitted", "unloc.tools/submit/thanks: received, pending review")
    page = text(3000)
    if "Too many" in page:
        raise RateLimited("too many submissions from this network")
    raise DriverFail(page[-300:])
