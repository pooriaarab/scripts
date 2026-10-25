"""llmstxt.info: German llms.txt directory. The free Standard tier needs no account, the site's
llms.txt URL and a category. Paid tiers and the paid hosting add-on are never chosen."""
import time

from lib import (CONTACT_EMAIL, RateLimited, Result, b, click, final_click, fit, go, must, refs, say, select, snap, text)

TARGET = "llmstxt.info (German llms.txt directory)"
DELAY = 10
RETRY_DAYS = 1
CATEGORY = {
    "agentsandboxes": "KI & Machine Learning", "agentwalletindex": "KI & Machine Learning",
    "creditunions": "Finanzen & Fintech", "datingcoaches": "Beratung & Agenturen", "doulas": "Gesundheit & Medizin",
    "drivingschool": "Fahrschule", "eatingdisorder": "Gesundheit & Medizin", "fertilityclinics": "Gesundheit & Medizin",
    "foreclosurelistings": "Immobilien", "french4pr": "Bildung & E-Learning", "immigrationhelp": "Beratung & Agenturen",
    "peptideclinic": "Gesundheit & Medizin", "petcremation": "Tierarzt & Tierpension",
    "psilocybincenters": "Gesundheit & Medizin", "robotaxis": "Reise & Tourismus", "soberbars": "Bar & Cocktailbar",
    "auctionfinder": "E-Commerce & Produkte",
}


def submit(site, p):
    go("https://llmstxt.info/submit/?tier=free", wait=6)
    click(must(snap(), r'button "STANDARD Kostenlos'))
    s = snap()
    org, url = refs(s, r'textbox "(?:NAME DER ORGANISATION|LLMS.TXT URL)')[:2]
    b("fill", "@" + org, p["name"])
    b("fill", "@" + url, p["url"] + "/llms.txt")
    select(0, CATEGORY[site])
    b("fill", "@" + must(s, r'textbox "GESCHÄFTLICHE E-MAIL'), CONTACT_EMAIL)
    b("fill", "@" + must(s, r'textbox "Zusätzlicher Kontext'), fit(p["short"], 400))
    click(must(s, r'checkbox "Bitte nicht auf X posten'))
    click(must(s, r'checkbox "Ich habe die AGB'))
    s = snap()
    if not final_click(must(s, r'button "Zur redaktionellen Prüfung')):
        return Result("skipped", "dry run")
    time.sleep(8)
    page = text(8000)
    if "Registrierung eingegangen" in page:
        return Result("submitted", "llmstxt.info/submit: 'Registrierung eingegangen. Deine Einsendung wird redaktionell geprüft' (free Standard tier, review within 48 hours)")
    if "Zu viele Anfragen" in page:
        raise RateLimited("'Zu viele Anfragen. Bitte später erneut versuchen.' after 4 submissions in a few minutes")
    return Result("blocked", "no confirmation after submit: " + say(page[-300:], 150))
