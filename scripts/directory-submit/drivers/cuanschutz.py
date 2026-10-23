"""CU Anschutz Strauss Library 'Tell us' form: a suggestion to add the site to the
Psychedelic and Sacred Plant Medicine guide. One site fits."""
import time

from lib import (CONTACT_EMAIL, Result, fill, final_click, go, must, say, snap, text)

TARGET = "CU Anschutz Strauss Health Sciences Library - Psychedelic and Sacred Plant Medicine guide (suggestion form)"
SITES = ["psilocybincenters"]
DELAY = 5
RETRY_DAYS = 1


def submit(site, p):
    go("https://library-cuanschutz.libanswers.com/tellus/index", wait=6)
    s = snap()
    fill(s, r'textbox "More Detail', (
        "Collections suggestion for the Psychedelic and Sacred Plant Medicine guide: "
        f"{p['name']} ({p['url']}). {p['short']} It is free to use and cites its public sources."))
    fill(s, r'textbox "Email \(if you do not', CONTACT_EMAIL)
    s = snap()
    if not final_click(must(s, r'button "Submit Your Question"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(4000)
    if "Thank you! You will get an email with the Library Response" in page:
        return Result("submitted", "library-cuanschutz.libanswers.com/tellus: 'Thank you! You will get an email with the Library Response once your comment or suggestion has been considered.'")
    return Result("blocked", "no confirmation after submit: " + say(page))
