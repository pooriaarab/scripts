"""Jayde web directory: free listing that goes live at once. Only drivingschool and fertilityclinics fit."""
from drivers.kit import generic

TARGET = "Jayde web directory"
SITES = ["drivingschool", "fertilityclinics"]
DELAY = 20
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://www.jayde.com/submit.html",
                   [(r'textbox "Your URL"', "url"), (r'textbox "Your email"', "email"),
                    (r'textbox "Business name"', "name"), (r'textbox "Business description"', "short")],
                   r'button "Add my Site"', r"thank|received|added|submitted|listed|success",
                   limit=r"too many|rate limit")
