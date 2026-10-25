"""Pro Launch: free launch (nofollow, 25 slots a week); 4-step wizard; account the maker mailbox (email+password, verified)."""
import json
import re
import time
from drivers.kit import long_text
from lib import *

TARGET = "Pro Launch"
DELAY = 8
RETRY_DAYS = 1


def submit(site, p):
    go("https://prolaunch.net/projects/submit", wait=6)
    dismiss_cookies()
    s = snap()
    if not find(s, r'textbox "Project Name'):
        raise DriverFail("form not open: " + say(text(200)))
    fill(s, r'textbox "Project Name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 150))
    ev("(()=>{const e=document.querySelector('.ProseMirror');e.focus();document.execCommand('insertText',false,%s)})()" % json.dumps(long_text(p)))
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    b("upload", "#f1", asset(site, "cover.png"))
    time.sleep(3)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    b("check", "@" + must(snap(), r'checkbox "Directories"'))
    b("check", "@" + must(snap(), r'checkbox "Web"'))
    b("check", "@" + must(snap(), r'radio "Free"'))
    r_ = must(snap(), r'textbox "Tags')
    for tg in ("directory", "listings", "api", "mcp"):
        b("fill", "@" + r_, tg)
        b("press", "Enter")
        time.sleep(0.3)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    # launch week: first option with free slots (option text ends with the count, e.g. 'Feb 2 - Feb 819 free slot(s)')
    opts = ev("[...document.querySelectorAll('select')][0] ? [...[...document.querySelectorAll('select')][0].options].map(o=>[o.text,o.value]) : []")
    pick = None
    for text_, val in opts or []:
        m = re.search(r"(\d+) free slot", text_)
        if m and val and int(m.group(1)[-1:] if len(m.group(1)) == 1 else m.group(1)) >= 0 and not text_.endswith("0 free slot(s)"):
            pick = text_
            break
    if not pick:
        raise DriverFail("no launch week with free slots")
    select_opt(pick)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    ref = must(snap(), r'button "Submit Project"')
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(9)
    page = text(2500)
    url = current_url()
    if "This project is scheduled for launch" in page:
        return Result("submitted", f"{url.split('?')[0].replace('https://', '')}: 'This project is scheduled for launch' status Scheduled, Free Launch ({pick})")
    raise DriverFail("no confirmation at " + url + ": " + say(page, 300))
