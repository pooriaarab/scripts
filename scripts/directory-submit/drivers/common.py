"""Shared data for the round 5 drivers: the fleet order and each site's topic.

A board has its own category list. A driver maps a topic to the board's category,
so the choice stays the same on every board."""

FLEET = ["agentsandboxes", "agentwalletindex", "creditunions", "datingcoaches", "doulas", "drivingschool",
         "eatingdisorder", "fertilityclinics", "foreclosurelistings", "french4pr", "immigrationhelp",
         "peptideclinic", "petcremation", "psilocybincenters", "robotaxis", "soberbars", "auctionfinder"]

TOPIC = {
    "agentsandboxes": "dev", "agentwalletindex": "finance", "creditunions": "finance", "datingcoaches": "social",
    "doulas": "health", "drivingschool": "education", "eatingdisorder": "health", "fertilityclinics": "health",
    "foreclosurelistings": "finance", "french4pr": "education", "immigrationhelp": "education",
    "peptideclinic": "health", "petcremation": "other", "psilocybincenters": "health", "robotaxis": "other",
    "soberbars": "social", "auctionfinder": "ecommerce",
}


def index(site):
    """Position of the site in the fleet. Used to spread launch dates over the weeks a board offers."""
    return FLEET.index(site)
