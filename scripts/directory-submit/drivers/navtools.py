"""NavTools.ai: Basic $0 plan (30-90 day review), quick submit with name, website and email."""
from drivers.kit import generic

TARGET = "NavTools.ai"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    def decline():
        from lib import click, find, snap
        ref = find(snap(), r'button "No thanks')
        if ref:
            click(ref)
    return generic(site, p, "https://navtools.ai/submit",
                   [(r'textbox "Tool Name', "name"), (r'textbox "Website URL', "url"), (r'textbox "Contact Email', "email")],
                   r'button "Submit AI Tool"', r"Thank you for submitting[^\n]*",
                   clicks=[r'radio "Basic Review'], after=decline, limit=r"too many|rate limit")
