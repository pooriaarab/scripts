"""backlinks.fyi Startup Showcase: free startup listing, manual review 24 to 48 hours, dofollow."""
from drivers.kit import generic

TARGET = "backlinks.fyi Startup Showcase"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": ["AI Tool", "Developer"], "agentwalletindex": ["AI Tool"], "other": ["Consumer Web", "Other"]}


def submit(site, p):
    return generic(site, p, "https://backlinks.fyi/submit-startup/form",
                   [(r'textbox "acme\.com', "url"), (r'textbox "e\.g\. Acme Corp', "name"),
                    (r'textbox "The AI platform', "tagline"), (r'textbox "you@startup', "email")],
                   r'button "Feature My Startup', r"submitted|thank|received|under review|we.ll review|success",
                   selects=[("@0", CAT)], bad=[r"already been submitted[^\n]*"], limit=r"too many|rate limit")
