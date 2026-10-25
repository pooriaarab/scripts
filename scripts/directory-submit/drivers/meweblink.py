"""MeWebLink: anonymous free directory form. Limit: 3 per 10 minutes and 20 per day."""
from drivers.kit import generic

TARGET = "MeWebLink free website directory"
SITES = ["datingcoaches", "soberbars", "petcremation", "peptideclinic", "doulas", "eatingdisorder"]
DELAY = 220
RETRY_DAYS = 1
CAT = {"social": ["Other"], "other": ["Shopping & Services", "Other"]}


def submit(site, p):
    return generic(site, p, "https://meweblink.com/submit/",
                   [(r'textbox "Website URL', "url"), (r'textbox "Website name', "name"),
                    (r'textbox "Short description', "short"), (r'textbox "Primary language', "=English")],
                   r'button "Submit website for free"', r"thank|received|submitted|published|added|success",
                   selects=[(r'combobox "Category"', CAT)], limit=r"too many|rate limit|try again", live=r"published|added to the directory")
