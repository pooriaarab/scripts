"""BuildShipper: free listing with a followed backlink; account the maker mailbox; Launch my listing lists it at once."""
import re
import subprocess
import time
from lib import *

TARGET = "BuildShipper"
DELAY = 10
RETRY_DAYS = 1


def submit(site, p):
    go("https://buildshipper.com/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if not find(s, r'textbox "Website URL"') and not find(s, r'button "Launch my listing"'):
        raise DriverFail("form not open: " + say(text(200)))
    if not find(s, r'textbox "Website URL"'):
        # a saved draft of an earlier site may be showing: go back to the URL step
        for pat in (r'button "Change URL"', r'button "Edit details"'):
            r_ = find(snap(), pat)
            if r_:
                click(r_)
                time.sleep(2)
        s = snap()
        if not find(s, r'textbox "Website URL"'):
            go("https://buildshipper.com/submit?new=1", wait=5)
            s = snap()
    if find(s, r'textbox "Website URL"'):
        fill(s, r'textbox "Website URL"', p["url"])
        click(must(snap(), r'button "Read this page"'))
        for _ in range(10):
            time.sleep(2)
            if find(snap(), r'textbox "Name"'):
                break
        fill(snap(), r'textbox "Name"', p["name"])
        fill(snap(), r'textbox "Tagline"', fit(p["tagline"], 100))
        click(must(snap(), r'button "Continue"'))
        time.sleep(4)
    ref = must(snap(), r'button "Launch my listing"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(1500)
    if "on this week's board right now" in page:
        m = re.search(r"buildshipper\.com/p/[a-z0-9\-]+", page)
        url = m.group(0) if m else ""
        code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "https://" + url], capture_output=True, text=True).stdout if url else ""
        return Result("live", f"{url} returns {code}; 'It is on this week's board right now' after Launch my listing")
    raise DriverFail("no confirmation: " + say(page, 300))
