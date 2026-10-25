"""Web Apps Directory: free standard listing, human review up to four weeks."""
from drivers.kit import generic

TARGET = "Web Apps Directory"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": ["Development Tools"], "finance": ["Finance"], "health": ["Health"], "education": ["Education"],
       "social": ["Social"], "transport": ["Shopping & Travel"], "ecommerce": ["Shopping"], "realestate": ["Finance"],
       "other": ["Utilities"]}


def submit(site, p):
    return generic(site, p, "https://webapps.directory/submit",
                   [(r'textbox "YOUR APP.S ADDRESS', "url"), (r'textbox "APP NAME', "name"),
                    (r'textbox "YOUR EMAIL', "email"), (r'textbox "SHORT DESCRIPTION', "short")],
                   r'button "Submit for review"', r"thank|received|submitted|in review|we.ll review|queue",
                   selects=[(r'combobox "CATEGORY"', CAT)], limit=r"too many|rate limit")
