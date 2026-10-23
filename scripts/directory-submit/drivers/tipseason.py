"""TipSeason AI Tools: an anonymous free listing form (dofollow, queue of 90+ days).
The board lists AI tools, so only the two agent sites fit."""
import time

from lib import (CONTACT_EMAIL, Result, click, current_url, fill, final_click, fit, go, must, say, select, snap, text)

TARGET = "TipSeason AI Tools"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 10
RETRY_DAYS = 1
USE_CASE = {"agentsandboxes": "Compare cloud sandboxes for AI agents", "agentwalletindex": "Compare wallets and payment rails for AI agents"}


def submit(site, p):
    go("https://www.tipseason.com/ai-tools/submit-free", wait=6)
    s = snap()
    fill(s, r'textbox "Your Email', CONTACT_EMAIL)
    fill(s, r'textbox "Tool Name', p["name"])
    fill(s, r'textbox "Short description', fit(p["short"], 150))
    fill(s, r'textbox "Long description', p["long"])
    select(0, "Development" if site == "agentsandboxes" else "Other")
    click(must(s, r'radio "Free"'))
    fill(s, r'textbox "Primary Use Case', USE_CASE[site])
    fill(s, r'textbox "Website URL', p["url"])
    click(must(s, r'radio "No, not at this time"'))
    fill(s, r'textbox "How did you hear', "Web search")
    s = snap()
    if not final_click(must(s, r'button "Submit for Review"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    if "submit-free/success" in current_url():
        return Result("submitted", "tipseason.com/ai-tools/submit-free/success: 'Your AI Tool Is In The Standard Queue' (free queue, 180+ days)")
    # The form was filed. Never raise after the final click: a retry would file it twice.
    return Result("blocked", "no confirmation page after submit: " + say(text(300)))
