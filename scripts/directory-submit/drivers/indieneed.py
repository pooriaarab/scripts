"""IndieNeed: free listing (nofollow, reviewed, up to 2 active products per account); account the maker mailbox."""
import re
import time
from lib import *

TARGET = "IndieNeed"
DELAY = 15
RETRY_DAYS = 1
SITES = ["agentsandboxes", "agentwalletindex"]
CAT = {"agentsandboxes": ["Developer Tools", "AI"], "agentwalletindex": ["Finance", "AI"]}


def submit(site, p):
    go("https://www.indieneed.com/submit", wait=7)
    dismiss_cookies()
    s = snap()
    if not find(s, r'textbox "Website URL"'):
        raise DriverFail("form not open: " + say(text(300)))
    fill(s, r'textbox "Website URL"', p["url"])
    fill(s, r'textbox "Product name"', p["name"])
    fill(s, r'textbox "One-line tagline"', fit(p["tagline"], 58))
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f0", asset(site, "logo.png"))
    time.sleep(3)
    click(must(snap(), r'button "Continue'))
    time.sleep(3)
    ev("document.querySelectorAll('input[type=file]').forEach((e,i)=>e.id='f'+i)")
    b("upload", "#f1", asset(site, "cover-xl.png"))
    time.sleep(4)
    click(must(snap(), r'button "Choose categories'))
    time.sleep(1)
    for c in CAT[site]:
        r_ = find(snap(), rf'option "{re.escape(c)}"')
        if r_:
            click(r_)
            time.sleep(0.5)
    ev("document.body.click()")
    # launch date: first open day
    d = ev("(()=>{const b=[...document.querySelectorAll('button')].find(b=>/^[A-Z][a-z]+ \\d+, (?!past|full)/i.test(b.getAttribute('aria-label')||'')&&!b.disabled&&!/Full/.test(b.innerText));if(!b)return 'NONE';b.scrollIntoView({block:'center'});b.click();return b.getAttribute('aria-label')})()")
    time.sleep(1)
    fill(snap(), r'textbox "Description"', fit(p["long"], 590))
    b("check", "@" + must(snap(), r'radio "Free listing'))
    ref = must(snap(), r'button "Continue with Free"')
    if not final_click(ref):
        return Result("skipped", "dry run: date " + str(d))
    time.sleep(8)
    page = text(2500)
    m = re.search(re.escape(p["name"]) + r" is in the review queue", page)
    if m and "/products/mine" in current_url():
        return Result("submitted", f"indieneed.com/products/mine: '{m.group(0)}', requested launch date {d}")
    raise DriverFail("no confirmation at " + current_url() + ": " + say(page, 300))
