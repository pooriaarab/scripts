"""Not Human Search: an anonymous form with one URL field."""
import time

from lib import DriverFail, Result, b, fill, final_click, go, must, snap

TARGET = "Not Human Search"
DELAY = 5
RETRY_DAYS = 1


def submit(site, p):
    go("https://nothumansearch.ai/submit")
    fill(snap(), r'textbox "Site URL', p["url"])
    if not final_click(must(snap(), r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    out = b("eval", "document.querySelector('#submit').innerText")
    if "Submitted!" in out:
        return Result("submitted", "nothumansearch.ai/submit said 'Submitted!'; check its search API for the domain")
    raise DriverFail(out[-300:])
