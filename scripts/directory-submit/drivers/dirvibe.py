"""DirVibe: free launch (no badge), account the maker mailbox; 4-step wizard; 150 word description; logo and image uploads."""
import json
import re
import time
import subprocess
from drivers.kit import values, KIND, long_text
from drivers.common import index
from lib import *

TARGET = "DirVibe"
DELAY = 10
RETRY_DAYS = 1
CAT = {"dev": "Developer Tools", "finance": "Finance", "health": "Lifestyle", "education": "Education", "social": "Lifestyle",
       "transport": "Directory", "ecommerce": "Business", "realestate": "Directory", "other": "Directory"}


def sn():
    return b("snapshot", "-i", "-C")


def chip(label):
    js = ("(()=>{const L=%s;const els=[...document.querySelectorAll('*')].filter(e=>e.children.length<=2&&e.innerText&&"
          "e.innerText.trim()===L&&getComputedStyle(e).cursor==='pointer');const e=els[0];if(!e)return 'NONE';"
          "e.scrollIntoView({block:'center'});e.click();return 'OK'})()") % json.dumps(label)
    if "OK" not in ev(js):
        raise DriverFail(f"chip {label!r} not found")
    time.sleep(0.5)


def submit(site, p):
    go("https://www.dirvibe.com/products/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if find(s, r'button "Log in|Sign in"') and not find(s, r'button "Next"'):
        raise DriverFail("signed out")
    click(must(s, r'button "Next"'))
    time.sleep(2)
    s = snap()
    fill(s, r'textbox "Project Name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(snap(), r'textbox "Project Description', long_text(p))
    time.sleep(1)
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    b("upload", "#f1", asset(site, "cover.png"))
    time.sleep(3)
    s = snap()
    if "disabled" in line(s, r'button "Next"'):
        raise DriverFail("step 2 Next disabled after uploads: " + say(ev("document.body.innerText.match(/Logo[\\s\\S]{0,200}/)?.[0] or ''"), 200))
    click(must(s, r'button "Next"'))
    time.sleep(2)
    for lab in (CAT[KIND[site]], "Web", "API", "Free"):
        chip(lab)
    s = snap()
    if "disabled" in line(s, r'button "Next"'):
        raise DriverFail("step 3 Next disabled")
    click(must(s, r'button "Next"'))
    time.sleep(3)
    # pick a launch week with free slots: spread the fleet over the weeks
    weeks = re.findall(r'generic "(W\d+20\d\d[^"]*Slots: (\d+) / 15Available)"', sn())
    free = [w for w, n in weeks if int(n) < 15 or True]
    if not free:
        raise DriverFail("no launch week offered")
    pick = free[min(1 + index(site) % 8, len(free) - 1)]
    click(must(sn(), r'generic "' + re.escape(pick)))
    time.sleep(1)
    s = snap()
    ref = must(s, r'button "Submit Product"')
    if "disabled" in line(s, r'button "Submit Product"'):
        raise DriverFail("Submit Product disabled")
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(2500)
    m = re.search(r"Submission Successful[^\n]*", page)
    pm = re.search(r"https://www\.dirvibe\.com/product/[a-z0-9\-]+", page)
    if m and pm:
        return Result("submitted", f"{pm.group(0)}: 'Submission Successful! Your product has been scheduled for launch.'")
    raise DriverFail("no confirmation: " + say(page, 300))
