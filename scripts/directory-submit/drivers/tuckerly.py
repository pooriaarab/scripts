"""Tuckerly Pet Partners: free pet loss support directory listing. Only petcremation fits."""
from drivers.kit import generic

TARGET = "Tuckerly Pet Partners (free pet loss support directory listing)"
SITES = ["petcremation"]
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://www.tuckerly.com/partners",
                   [(r'textbox "Happy Paws', "name"), (r'textbox "Jane"', "=Pooria"), (r'textbox "Smith"', "=Arab"),
                    (r'textbox "clinic@example', "email")],
                   r'button "Submit"', r"thank|received|submitted|success|we.ll be in touch",
                   limit=r"too many|rate limit")
