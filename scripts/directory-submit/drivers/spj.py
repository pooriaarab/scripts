"""SPJ Journalist's Toolbox: an anonymous Jotform that suggests a resource.
SPJ accepts a link on its value to reporters, so only data sites that a
reporter can use are filed."""
import time

from lib import (CONTACT_EMAIL, DriverFail, Result, fill, final_click, fit, go, must, setting, snap, text)

TARGET = "SPJ Journalist's Toolbox (Suggest resource)"
SITES = ["foreclosurelistings", "creditunions", "fertilityclinics", "immigrationhelp", "robotaxis"]
DELAY = 8
RETRY_DAYS = 1
PAGES = {
    "foreclosurelistings": "Real estate and public records",
    "creditunions": "Business and finance",
    "fertilityclinics": "Health, public data",
    "immigrationhelp": "Immigration",
    "robotaxis": "Transportation and technology",
}


def submit(site, p):
    go("https://form.jotform.com/231504845610046", wait=6)
    s = snap()
    name = setting("DIRSUB_MAKER_NAME").split(" ", 1)
    fill(s, r'textbox "First Name', name[0])
    fill(s, r'textbox "Last Name', name[-1])
    fill(s, r'textbox "Email', CONTACT_EMAIL)
    fill(s, r'textbox "Title, workplace', "Founder, " + setting("DIRSUB_COMPANY"))
    fill(s, r'textbox "Website name', p["name"])
    fill(s, r'textbox "Website URL', p["url"])
    fill(s, r'textbox "Description of the website', fit(p["short"], 280))
    fill(s, r'textbox "Which page', PAGES[site])
    s = snap()
    if not final_click(must(s, r'button "Submit"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(600)
    if "Thank" in page:
        return Result("submitted", "form.jotform.com SPJ Toolbox suggest form: 'Thank You' page shown after submit; SPJ reviews each link")
    raise DriverFail(page[:300])
