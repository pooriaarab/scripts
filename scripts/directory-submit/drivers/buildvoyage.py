"""BuildVoyage: needs a maker email at the product's own domain, then an emailed confirm link.
The board returns HTTP 429 after about 9 submissions in 70 minutes.
`run.py buildvoyage --confirm` clicks the emailed links and records the result."""
import re
import sys
import time
from urllib.parse import urlparse

import ledger
from lib import (DriverFail, RateLimited, Result, asset, b, click, fill, final_click, find, fit, go, gog,
                 line, must, packet, snap, text, wait_ref)

TARGET = "BuildVoyage"
DELAY = 20
RETRY_DAYS = 1
CATEGORY = "Directory & Listings"
STACK = ("+ Next.js", "Infrastructure", "+ Cloudflare")  # the template's stack, in click order


def submit(site, p):
    go("https://buildvoyage.com/submit")
    s = snap()
    accept = find(s, r'button "Accept"')
    if accept:
        click(accept)
        s = snap()
    fill(s, r'textbox "Product Name', p["name"])
    fill(s, r'textbox "Tagline', fit(p["tagline"], 80))
    box = re.search(r"textbox \[ref=(e\d+)\]", s)  # the description box has no label
    if not box:
        raise DriverFail("description box not found")
    b("fill", "@" + box.group(1), p["long"])
    fill(s, r'textbox "Website', p["url"])
    fill(s, r'textbox "Your email', p["contact_email"])  # must sit on the product domain
    b("select", "@" + must(s, r'combobox "Category'), CATEGORY)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    b("upload", "input[type=file]", asset(site, "logo.png"))
    time.sleep(3)
    click(must(snap(), r'button "Next"'))
    time.sleep(3)
    for label in STACK:
        ref, _ = wait_ref(r'button "' + re.escape(label) + '"')
        click(ref)
        time.sleep(1)
    s = snap()
    if "checked=false" in line(s, 'checkbox "I built'):
        b("check", "@" + must(s, r'checkbox "I built'))
    time.sleep(3)
    if not final_click(must(snap(), r'button "Submit and confirm by email"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(1500)
    if "429" in page[:20] or "TOO MANY" in page[:40]:
        raise RateLimited("HTTP 429 from BuildVoyage")
    if "Please fix" in page:
        raise DriverFail(page[page.find("Please fix"):][:300])
    return Result("submitted", "email sent; run `run.py buildvoyage --confirm` to click the link")


def confirm(sites):
    """Click every emailed BuildVoyage confirm link and record the sites it confirms.
    A row is written only when the confirmation page shows the site name or its host.
    A page that shows neither raises DriverFail after the other links are done."""
    packets = {packet(s)["name"]: packet(s) for s in sites}
    out = gog("gmail", "search", "from:updates.buildvoyage.com subject:Confirm newer_than:1d", "--max", "40")
    done = set()
    wrong = []
    for row in out.strip().split("\n")[1:]:
        if not row.strip():
            continue
        thread = gog("gmail", "thread", "get", row.split()[0])
        link = re.search(r"https://buildvoyage\.com/submit/verify/[A-Za-z0-9]+", thread)
        subject = re.search(r"Subject: Confirm your BuildVoyage submission: (.*)", thread)
        name = subject.group(1).strip() if subject else ""
        if not link or name in done or name not in packets:
            continue
        done.add(name)
        go(link.group(0))
        button = find(snap(), r'button "Confirm my submission"')
        if not button:
            print(f"{name}: no confirm button")
            continue
        click(button)
        time.sleep(5)
        p = packets[name]
        page = text(1500).lower()
        if name.lower() not in page and urlparse(p["url"]).netloc.lower() not in page:
            wrong.append(name)
            print(f"{name}: confirmation page shows neither the site name nor {urlparse(p['url']).netloc}; no ledger row",
                  file=sys.stderr)
            continue
        ledger.record(TARGET, p["site"], "submitted",
                      f"https://buildvoyage.com/products/{p['site']} (email confirmed, under review, free 48 hour review)")
        print(f"{name}: confirmed")
    if wrong:
        raise DriverFail("confirmation page did not match the packet for: " + ", ".join(wrong))
