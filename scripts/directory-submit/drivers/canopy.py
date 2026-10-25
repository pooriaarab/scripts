"""Canopy Launch Directory: anonymous one-step form (name, URL, pitch, category)."""
from drivers.kit import generic, pick

TARGET = "Canopy Launch Directory"
DELAY = 10
RETRY_DAYS = 1
CAT = {"dev": "Dev tool", "other": "Other"}


def submit(site, p):
    return generic(site, p, "https://canopystack.dev/launches",
                   [(r'textbox "Name"', "name"), (r'textbox "URL"', "url"), (r'textbox "One-line pitch', "tagline")],
                   r'button "List it', r"listed|added|thanks|thank you|published|live|received",
                   selects=[(r'combobox "Category"', pick(CAT))], limit=r"too many|rate limit", live=r"you.re listed")
