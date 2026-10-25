"""PromoteIndex: anonymous free form (name, site, tagline, category, description, tags)."""
from drivers.kit import generic

TARGET = "PromoteIndex"
DELAY = 20
RETRY_DAYS = 1
CAT = {"agentsandboxes": ["AI Agents"], "agentwalletindex": ["AI Agents"], "other": ["SaaS"]}


def submit(site, p):
    return generic(site, p, "https://promoteindex.com/submit",
                   [(r'textbox "PROJECT NAME', "name"), (r'textbox "WEBSITE', "url"), (r'textbox "TAGLINE', "tagline"),
                    (r'textbox "DESCRIPTION', "short"), (r'textbox "TAGS', "tags"),
                    (r'textbox "CONTACT EMAIL', "email")],
                   r'button "LIST IT', r"201 CREATED[^\n]*",
                   selects=[(r'combobox "CATEGORY', CAT), (r'combobox "WHERE DID YOU HEAR', "Something else")], limit=r"too many|rate limit", live=r"YOU.RE LISTED")
