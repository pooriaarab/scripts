"""Shipboard: post a site address with a category and an email; no password."""
from drivers.kit import generic

TARGET = "Shipboard"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": ["Developer tools", "AI"], "finance": ["Finance"], "health": ["Health"], "education": ["Education"],
       "social": ["Social"], "transport": ["Travel"], "ecommerce": ["E-commerce"], "realestate": ["Finance"],
       "other": ["Other"]}


def submit(site, p):
    return generic(site, p, "https://shipboard.live/submit",
                   [(r'textbox "Your site.s address', "url"), (r'textbox "Description', "short"),
                    (r'textbox "Your name or brand', "?name"), (r'textbox "Where should we send', "?email")],
                   r'button "Post it[^"]*"', r"You.re on the board[^\n]*",
                   selects=[(r'combobox "Category', CAT)], limit=r"too many|rate limit", live=r"You.re on the board")
