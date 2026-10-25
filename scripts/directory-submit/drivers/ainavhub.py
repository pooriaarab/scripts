"""AI NavHub: free submit form (name, URL, email). Only the two agent sites fit."""
from drivers.kit import generic

TARGET = "AI NavHub"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://ainavhub.com/submit",
                   [(r'textbox "Website Name"', "name"), (r'textbox "Website URL"', "url"), (r'textbox "Email"', "email")],
                   r'button "Submit"', r"thank|received|submitted|success",
                   limit=r"too many|rate limit")
