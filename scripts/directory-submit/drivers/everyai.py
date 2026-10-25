"""EveryAI: paste the link, review the details, pick the free $0 plan, submit."""
import time

from drivers.kit import generic
from lib import account, b, click, current_url, fill, find, go, must, snap, type_secret

TARGET = "EveryAI"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": ["Code"], "finance": ["Finance"], "health": ["Healthcare"], "education": ["Education"],
       "immigrationhelp": ["Legal"], "social": ["Personal"], "ecommerce": ["Business"], "realestate": ["Finance"],
       "other": ["Other"]}


def submit(site, p):
    def first(v):
        if "sign-in" in current_url():
            email, pw = account("EveryAI")
            s = snap()
            if find(s, r'button "Create an account'):
                pass
            fill(s, r'textbox "Email"', email)
            type_secret(must(s, r'textbox "Password"'), pw)
            click(must(snap(), r'button "Sign in"'))
            time.sleep(5)
            go("https://every-ai.com/submit", wait=5)
        s = snap()
        if not find(s, r'textbox "Website URL') and find(s, r'button "← Back'):
            click(find(s, r'button "← Back'))
            time.sleep(2)
        fill(snap(), r'textbox "Website URL', v["url"])
        click(must(snap(), r'button "Continue'))
        time.sleep(7)
    return generic(site, p, "https://every-ai.com/submit",
                   [(r'textbox "Tool name', "name"), (r'textbox "Short description', "short"),
                    (r'textbox "Key features', "features"), (r'textbox "Contact email', "email")],
                   r'button "Submit tool"', r"submitted|thank|received|under review|in review|live within",
                   pre=first, selects=[(r'combobox "Category"', CAT), (r'combobox "Subcategory"', "*first")],
                   clicks=[r'radio "\$0 STANDARD'], limit=r"too many|rate limit")
