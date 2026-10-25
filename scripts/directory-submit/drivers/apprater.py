"""App Rater: free submission (human review), no account; platform picker is a custom dropdown, set with JS clicks."""
import re
import time
from lib import *

TARGET = "App Rater"
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    go("https://apprater.net/", wait=6)
    ev("[...document.querySelectorAll('button')].filter(b=>/Reject analytics/.test(b.innerText)).forEach(b=>b.click())")
    s = snap()
    fill(s, r'textbox "App name"', p["name"])
    fill(s, r'textbox "App or store URL"', p["url"])
    fill(s, r'textbox "What makes it useful', fit(p["short"], 300))
    fill(s, r'textbox "Your name"', "Pooria Arab")
    fill(s, r'textbox "Email"', CONTACT_EMAIL)
    r1 = ev("(()=>{const b=[...document.querySelectorAll('button,div,span')].find(e=>e.innerText&&e.innerText.trim().startsWith('Select platforms')&&e.children.length<=3);if(!b)return 'NONE';b.scrollIntoView({block:'center'});b.click();return 'OK'})()")
    time.sleep(1)
    r2 = ev("(()=>{const e=[...document.querySelectorAll('[role=option],[role=menuitemcheckbox],li,label')].filter(e=>e.innerText.trim()==='Web').pop();if(!e)return 'NONE';e.click();return 'OK'})()")
    if "OK" not in str(r1) or "OK" not in str(r2):
        raise DriverFail(f"platform picker: {r1} {r2}")
    time.sleep(1)
    ref = must(snap(), r'button "Submit for review"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = ev("(document.querySelector('#submit')||document.body).innerText")
    m = re.search(r"SUBMISSION RECEIVED\s*\n\s*([^\n]+)", str(page))
    if m:
        return Result("submitted", f"apprater.net: 'SUBMISSION RECEIVED. {say(m.group(1), 100)}'")
    raise DriverFail("no confirmation: " + say(str(page), 300))
