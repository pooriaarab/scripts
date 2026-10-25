"""Linkrena: anonymous form, permanent dofollow link, quality check publishes automatically."""
from drivers.kit import generic

TARGET = "Linkrena"
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://linkrena.com/submit",
                   [(r'textbox "Product URL', "url"), (r'textbox "Name"', "name"),
                    (r'textbox "One-line description', "tagline"), (r'textbox "Email', "email")],
                   r'button "Submit for review"', r"submitted|received|thanks|thank you|review|live",
                   limit=r"too many|rate limit", live=r"is live|published")
