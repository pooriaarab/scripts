"""Infrabase: free AI infrastructure directory, anonymous form. Only the two agent sites fit."""
from drivers.kit import generic

TARGET = "Infrabase"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://infrabase.ai/submit",
                   [(r'textbox "Product name', "name"), (r'textbox "URL"', "url"), (r'textbox "Brief description', "short"),
                    (r'textbox "Contact email', "email")],
                   r'button "Submit"', r"thank|received|submitted|we.ll review|success",
                   limit=r"too many|rate limit")
