"""ResearchBuzz: the site submission form on the contact page. The blog covers search tools,
databases and online information collections. The owner states the site is theirs and gives
a 10-20 word summary, as the rules page asks. The sponsored-post box stays empty."""
import time

from lib import (CONTACT_EMAIL, Result, b, final_click, go, must, refs, say, setting, snap, text)

TARGET = "ResearchBuzz (site submission form)"
SITES = ["agentsandboxes", "agentwalletindex", "foreclosurelistings", "robotaxis"]
DELAY = 15
RETRY_DAYS = 1
SUMMARY = {
    "agentsandboxes": "A free index of cloud sandbox providers for AI agents, with source-linked specs and a free API.",
    "agentwalletindex": "A free index of wallets and payment rails for AI agents, with source-linked specs and a free API.",
    "foreclosurelistings": "A free guide to foreclosure sales by place: sale venues, counselors, legal aid, with a free API.",
    "robotaxis": "A free city-by-city guide to where robotaxis operate today, with sources and a free API.",
}


def submit(site, p):
    go("https://researchbuzz.me/contact/", wait=6)
    s = snap()
    name, email, sname, surl, spons, msg = refs(s, r'textbox "(?:Name|Email|Site Name|Site URL|For Sponsored|Tell me all)')[:6]
    b("fill", "@" + name, setting("DIRSUB_MAKER_NAME"))
    b("fill", "@" + email, CONTACT_EMAIL)
    b("fill", "@" + sname, p["name"])
    b("fill", "@" + surl, p["url"])
    b("fill", "@" + spons, "This is not a sponsored post or link exchange request. I own the site and send it for your information.")
    b("fill", "@" + msg, f"This is my site. {SUMMARY[site]}")
    s = snap()
    if not final_click(must(s, r'button "SUBMIT"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(9000)
    if "Thank you for your response." in page:
        return Result("submitted", "researchbuzz.me/contact: 'Thank you for your response.' with the submitted values echoed back")
    return Result("blocked", "form did not accept the submit: " + say(page[page.find("Please fill"):], 150))
