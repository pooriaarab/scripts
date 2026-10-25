"""Shipycorn: same launch-board template as FridayHunt (magic-link sign-in, 4-step wizard).
Reuses fridayhunt.launch with this board's address."""
from drivers.fridayhunt import launch

TARGET = "Shipycorn"
DELAY = 12
RETRY_DAYS = 1


def submit(site, p):
    return launch(site, p, "https://shipycorn.com", "shipycorn")
