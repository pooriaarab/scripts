"""BSDirectory: free submission, two steps (details, then the Free Launch plan). Launch at least 30 days after approval."""
import time

from drivers.kit import generic

TARGET = "BSDirectory"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": ["Developer Tools"], "finance": ["Finance"], "education": ["Education"], "other": ["Utilities", "Other"]}


def submit(site, p):
    def free():
        from lib import click, find, snap
        time.sleep(2)
        ref = find(snap(), r'button "Submit for free"')
        if ref:
            click(ref)
    def cookies(v):
        from lib import click, find, snap
        ref = find(snap(), r'button "Decline analytics"')
        if ref:
            click(ref)
    return generic(site, p, "https://directory.project-bs.com/submit",
                   [(r'textbox "Product name"', "name"), (r'textbox "Website URL"', "url"), (r'textbox "Tagline"', "tagline"),
                    (r'textbox "Founder name"', "maker"), (r'textbox "Contact email"', "email")],
                   r'button "Continue to launch options"', r"Your product has been submitted[^\n]*",
                   selects=[(r'combobox "Product category"', CAT), (r'combobox "Product type"', "Directory")],
                   after=free, pre=cookies, limit=r"too many|rate limit|Please wait before submitting[^\n]*")
