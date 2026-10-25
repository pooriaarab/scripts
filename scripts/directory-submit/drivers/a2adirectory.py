"""a2a.directory: anonymous form that fetches and validates the site's A2A agent card.
Every fleet site serves /.well-known/agent-card.json. Live agents that pass checks are listed."""
import time

from lib import (CONTACT_EMAIL, Result, b, ev, final_click, fit, go, must, refs, say, setting, snap, text)

TARGET = "a2a.directory"
DELAY = 8
RETRY_DAYS = 1


def submit(site, p):
    go("https://a2a.directory/submit/", wait=5)
    s = snap()
    name, card, desc, web, _icon, pub, pub_url, mail = refs(s, r'textbox "')[:8]
    b("fill", "@" + name, p["name"])
    b("fill", "@" + card, p["url"] + "/.well-known/agent-card.json")
    b("fill", "@" + desc, fit(p["short"], 250))
    b("fill", "@" + web, p["url"])
    b("fill", "@" + pub, setting("DIRSUB_COMPANY"))
    b("fill", "@" + mail, CONTACT_EMAIL)
    s = snap()
    if not final_click(must(s, r'button "Submit Agent"')):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(900)
    if "Your agent passed validation and is now live" in page:
        link = ev("[...document.querySelectorAll('a')].filter(a=>/View listing/.test(a.textContent)).map(a=>a.href)[0]||''")
        return Result("live", f"{link} : 'Agent Live! Your agent passed validation and is now live in the directory.'")
    return Result("blocked", "no live confirmation after submit: " + say(page, 150))
