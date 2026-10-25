"""Today Launches: free launch queue (2-3 months) through a public Tally form; no account."""
import re
import time
from lib import *

TARGET = "Today Launches"
DELAY = 8
RETRY_DAYS = 1


def submit(site, p):
    go("https://tally.so/r/n0404Q", wait=6)
    s = snap()
    fill(s, r'textbox "Full Name"', "Pooria Arab")
    fill(s, r'textbox "Email Address"', CONTACT_EMAIL)
    fill(s, r'textbox "Product Name"', p["name"])
    fill(s, r'textbox "Product Website"', p["url"])
    fill(s, r'textbox "Tagline / Slogan"', fit(p["tagline"], 120))
    ups = refs(snap(), r'button "(?:Logo \(Square\)|Click to choose a file)')
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    b("check", "@" + must(snap(), r'radio "Free"'))
    s = snap()
    if not re.search(r'radio "Free"[^\]]*checked=true', s):
        raise DriverFail("Free plan not selected")
    ref = must(s, r'button "Submit"')
    before = text(3000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(3000)
    m = re.search(r"(?i)[^\n]*(thank|submitted|received|success|we.ll be in touch)[^\n]*", page)
    if m and m.group(0) not in before:
        return Result("submitted", f"tally.so/r/n0404Q: '{say(m.group(0), 150)}'")
    raise DriverFail("no confirmation: " + say(page, 300))
