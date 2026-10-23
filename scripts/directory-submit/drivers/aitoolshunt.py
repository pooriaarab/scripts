"""AI Tools Hunt: a free listing form. The page shows no confirmation, so an unclear
result is recorded as blocked and a person checks the board. Never file a site twice."""
import re
import time

from lib import (CONTACT_EMAIL, Result, category, click, current_url, fill, final_click, go, line, must,
                 setting, snap, text)

TARGET = "AI Tools Hunt"
DELAY = 10
RETRY_DAYS = 365
DEFAULT_CATEGORY = "AI Agents"


def submit(site, p):
    go("https://aitoolshunt.com/submit-ai-tool/")
    s = snap()
    fill(s, r'textbox "Tool Name', p["name"])
    fill(s, r'textbox "Tool Website URL', p["url"])
    fill(s, r'textbox "AI Tool Category', category(p, "aitoolshunt", DEFAULT_CATEGORY))
    fill(s, r'textbox "Tool Description', p["short"])
    click(must(s, r'radio "Free Listing'))
    fill(s, r'textbox "Tool Logo', p["url"] + "/favicon.ico")
    fill(s, r'textbox "Name \*', setting("DIRSUB_MAKER_NAME"))
    fill(s, r'textbox "Email Address', CONTACT_EMAIL)
    fill(s, r'textbox "Company', setting("DIRSUB_COMPANY"))
    click(must(s, r'checkbox "Submission Terms'))
    s = snap()
    if not line(s, r'radio "Free') or not line(s, "Submission Terms"):
        return Result("blocked", "free radio or terms box missing before submit")
    if not final_click(must(s, r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    if re.search(r"(?i)thank you|success|received", text(900)):
        return Result("submitted", f"{current_url()} (form confirmation shown)")
    return Result("blocked", "form reset with no confirmation or listing visible; cannot verify, do not file again")
