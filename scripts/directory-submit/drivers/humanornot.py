"""Human or Not AI Tools: free listing within 48 hours, email and URL only. AI features required."""
from drivers.kit import generic

TARGET = "Human or Not AI Tools"
SITES = ["agentsandboxes", "agentwalletindex"]
DELAY = 15
RETRY_DAYS = 1


def submit(site, p):
    return generic(site, p, "https://www.humanornot.co/submit-tool",
                   [(r'textbox "Email:"', "email"), (r'textbox "humanornot\.co"', "url")],
                   r'button "Submit"', r"thank|received|submitted|success",
                   limit=r"too many|rate limit")
