"""Collective AI Tools: a catalog of AI tools, MCP servers and skills. Email and password
sign-up (no mail check), then the AI Tool form. Only the two agent sites fit the catalog."""
import time

from lib import (DriverFail, Result, account, b, click, fill, final_click, find, fit, go, must, say, setting, snap, text,
                 type_secret)

TARGET = "Collective AI Tools (web form)"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 10
RETRY_DAYS = 1
CATEGORY = {"agentsandboxes": "Developer Tools", "agentwalletindex": "Finance"}


def login():
    go("https://collectiveai.tools/submit", wait=6)
    if find(snap(), r'button "Log out"'):
        return
    email, pw = account("CollectiveAI")
    go("https://collectiveai.tools/login", wait=5)
    s = snap()
    fill(s, r'textbox "Email address', email)
    type_secret(must(s, r'textbox "Password'), pw)
    click(must(snap(), r'button "Sign in"'))
    time.sleep(5)
    go("https://collectiveai.tools/submit", wait=6)
    if not find(snap(), r'button "Log out"'):
        go("https://collectiveai.tools/register", wait=5)  # first run: make the account
        s = snap()
        fill(s, r'textbox "Full Name', setting("DIRSUB_MAKER_NAME"))
        fill(s, r'textbox "Email address', email)
        type_secret(must(s, r'textbox "Password'), pw)
        click(must(snap(), r'button "Sign up"'))
        time.sleep(6)
        go("https://collectiveai.tools/submit", wait=6)
        if not find(snap(), r'button "Log out"'):
            raise DriverFail("not signed in after sign-up")


def submit(site, p):
    login()
    s = snap()
    click(must(s, r'button "AI Tool"'))
    time.sleep(2)
    s = snap()
    fill(s, r'textbox "e.g. ChatGPT', p["name"])
    fill(s, r'textbox "Briefly describe', fit(p["short"], 250))
    fill(s, r'textbox "https://', p["url"])
    b("type", "@" + must(s, r'textbox "Categories'), CATEGORY[site])
    time.sleep(1.5)
    click(must(snap(), r'button "' + CATEGORY[site] + '"'))
    fill(snap(), r'textbox "Comma separated tags', "directory, api, mcp, free")
    click(must(snap(), r'button "Select pricing'))
    time.sleep(1)
    click(must(snap(), r'option "Free"'))
    s = snap()
    if not final_click(must(s, r'button "Submit Resource"')):
        return Result("skipped", "dry run")
    time.sleep(6)
    page = text(800)
    if "Submission Received!" in page:
        return Result("submitted", "collectiveai.tools/submit: 'Submission Received! Your submission is under review and will be listed once approved.' (account hello@example.xyz)")
    return Result("blocked", "no confirmation after submit: " + say(page, 150))
