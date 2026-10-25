"""Neeed Directory: verify the badge on each product page.
The listing exists from round 1. This driver clicks "Verify Badge" so the outbound
link loses nofollow. The board allows about 10 actions an hour, so DELAY is 6 minutes.
The product slug is the slug of the site name. Set `neeed_slug` in the packet to override."""
import time
from urllib.parse import urlparse

from lib import DriverFail, Result, b, click, find, go, slug, snap

TARGET = "Neeed Directory"
DELAY = 360
RETRY_DAYS = 1


def submit(site, p):
    page = f"https://neeed.directory/products/{p.get('neeed_slug') or slug(p['name'])}"
    host = urlparse(p["url"]).netloc
    go(page)
    s = snap()
    if "Badge Verified" not in s:
        verify = find(s, r'button "Verify Badge"')
        if not verify:
            return Result("blocked", f"{page}: no Verify Badge button; the listing may be held under review")
        click(verify)
        time.sleep(6)
        go(page)
        if "Badge Verified" not in snap():
            raise DriverFail(f"{page}: badge not verified; check the badge on the live site first")
    rel = b("eval", f"[...document.querySelectorAll('a')].filter(a=>/{host}/.test(a.href)).map(a=>a.rel).join('|')")
    rel = rel.strip().split("\n")[-1]
    return Result("live", f"{page} (badge verified; outbound link rel={rel or 'none'})")
