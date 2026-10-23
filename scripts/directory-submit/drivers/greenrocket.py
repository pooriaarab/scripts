"""GreenRocket: email sign-up, then a scheduled launch page at /launch/<slug>.
The board allows at most 10 launches a day. Calendar days are not in the
interactive snapshot, so the first enabled day is clicked with eval."""
import re
import time

from lib import (DriverFail, Result, asset, b, category, click, current_url, fill, final_click, find, fit,
                 go, must, snap, text, wait_ref)

TARGET = "GreenRocket"
DELAY = 10
RETRY_DAYS = 1
DEFAULT_CATEGORY = "Other Tools"
PICK_DAY = ("(()=>{const bs=[...document.querySelectorAll('.rdp-button')]"
            ".filter(e=>!e.disabled&&/^\\d+$/.test(e.innerText)); bs[0].click()})()")


def submit(site, p):
    go("https://greenrocket.app/create")
    s = snap()
    discard = find(s, r'button "Discard draft"')
    if discard:
        click(discard)
        time.sleep(2)
        s = snap()
    fill(s, r'textbox "Product Name', p["name"])
    fill(s, r'textbox "Product URL', p["url"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 100))
    fill(s, r'textbox "Description', p["long"])
    b("upload", "#upload-logos", asset(site, "logo.png"))
    b("upload", "#upload-screenshots", asset(site, "cover.png"))
    time.sleep(8)
    click(must(snap(), r'button "Continue"'))
    pattern = r'button "(?:SUGGESTED )?[^"]*' + re.escape(category(p, "greenrocket", DEFAULT_CATEGORY)) + '"'
    wait_ref(pattern)
    for _ in range(2):  # the category click can need a second try
        time.sleep(2)
        click(must(snap(), pattern))
        time.sleep(2)
        click(must(snap(), r'button "Continue"'))
        time.sleep(4)
        if "Pick Your Launch Day" in text(1500, 500):
            break
    else:
        raise DriverFail("stuck on the category step")
    b("eval", PICK_DAY)
    time.sleep(1)
    ref, _ = wait_ref(r'button "Launch It')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(7)
    url = current_url()
    if "/launch/" in url:
        return Result("submitted", f"{url} (scheduled launch page is live)")
    raise DriverFail(f"{url} {text(300)}")
