"""SEO Listing: anonymous free standard listing, a person reviews it within 24 hours and emails the link."""
from drivers.kit import generic

TARGET = "SEO Listing"
DELAY = 20
RETRY_DAYS = 1
CAT = {"agentsandboxes": ["AI & Online"], "agentwalletindex": ["Technology"], "creditunions": ["Professional Services"],
       "datingcoaches": ["Professional Services"], "drivingschool": ["Education"], "french4pr": ["Education"],
       "immigrationhelp": ["Professional Services"], "foreclosurelistings": ["Real Estate"], "soberbars": ["Restaurants"],
       "robotaxis": ["Automotive"], "auctionfinder": ["Retail"], "health": ["Health"], "other": ["Other Businesses"]}


def submit(site, p):
    def tick():
        from lib import b, find, line, snap
        s = snap()
        ref = find(s, r'checkbox "This is a real business')
        if ref and "checked=false" in line(s, r'checkbox "This is a real business'):
            b("check", "@" + ref)
    return generic(site, p, "https://seolisting.io/add-listing",
                   [(r'textbox "Website"', "url"), (r'textbox "Business name"', "name"), (r'textbox "Description"', "short"),
                    (r'textbox "Your name"', "maker"), (r'textbox "Your email"', "email")],
                   r'button "Submit listing"', r"thank|received|submitted|review|we.ll email",
                   selects=[(r'combobox "Category', CAT)], pre=None, limit=r"too many|rate limit", gap=1, post=tick)
