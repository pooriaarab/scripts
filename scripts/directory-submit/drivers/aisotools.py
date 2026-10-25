"""AISO Tools: anonymous free listing, nofollow backlink, auto published."""
from drivers.kit import generic, pick

TARGET = "AISO Tools"
DELAY = 20
RETRY_DAYS = 1
CAT = {"dev": "🤖 AI Agent Infrastructure", "finance": "💼 Business & Finance", "health": "🏥 Healthcare & Wellness",
       "education": "📚 Education & Research", "realestate": "🏡 Real Estate", "social": "🔍 Search & Knowledge",
       "transport": "🔍 Search & Knowledge", "ecommerce": "🔍 Search & Knowledge", "other": "🔍 Search & Knowledge"}


def submit(site, p):
    return generic(site, p, "https://aisotools.com/submit",
                   [(r'textbox "yourtool\.com', "domain"), (r'textbox "Autofill fills', "name"),
                    (r'textbox "One sentence', "tagline"), (r'textbox "Describe your tool', "short"),
                    (r'textbox "e\.g\., AI code', "=Directory listings, Search by place, Free API and MCP, Cited sources"),
                    (r'textbox "you@company\.com', "email")],
                   r'button "Submit Tool', r"is live|published|received|thank you",
                   selects=[("@0", pick(CAT)), ("@1", "Free")], limit=r"too many|rate limit", live=r"is live")
