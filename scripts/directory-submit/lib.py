"""Shared helpers for the directory-submit drivers.

A driver fills one directory's form in the owner's logged-in Chrome
(`browser-personal`, agent-browser). This module holds what every driver
needs: the browser call, snapshot ref lookup, the site packet, asset paths,
settings and the Gmail reader. It never types a password. The browser
profile holds the logins.
"""
import json
import os
import re
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

BROWSER = os.environ.get("DIRSUB_BROWSER", "browser-personal")
REPO = Path(os.environ.get("DIRSUB_REPO", ".")).resolve()
ASSETS = Path(os.environ.get("DIRSUB_ASSETS", "assets"))
SECRETS_FILE = Path(os.environ.get("DIRSUB_SECRETS_FILE", "~/.secrets/directory-submission.env")).expanduser()
# The only account address a driver may type into a form.
CONTACT_EMAIL = os.environ.get("DIRSUB_EMAIL", "hello@example.xyz")


class DriverFail(Exception):
    """The run did not finish. Nothing is recorded, so the next run retries."""


class RateLimited(Exception):
    """The directory refused more submissions. Stop the loop and record a retry date."""


@dataclass
class Result:
    status: str  # submitted | live | blocked | skipped
    note: str  # proof URL or message for submitted/live, reason for the rest


def setting(name):
    """Read NAME from the environment, else from the secrets file (NAME=value lines).
    Errors name the setting and never show a value."""
    if os.environ.get(name):
        return os.environ[name]
    if SECRETS_FILE.exists():
        for line in SECRETS_FILE.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name and value.strip():
                return value.strip().strip("'\"")
    raise DriverFail(f"setting {name} is not set (environment or {SECRETS_FILE})")


def dry_run():
    return os.environ.get("DIRSUB_DRY_RUN") == "1"


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def packet(site):
    """Site data from sites/<site>/data/submission.json. Name, tagline and domain
    come from directory.config.ts unless the JSON sets name, tagline or url."""
    base = REPO / "sites" / site
    p = json.loads((base / "data" / "submission.json").read_text())
    config = (base / "directory.config.ts").read_text()

    def field(key):
        m = re.search(rf'^\s*{key}:\s*("(?:[^"\\]|\\.)*")', config, re.M)
        return json.loads(m.group(1)) if m else ""

    p.setdefault("name", field("name"))
    p.setdefault("tagline", field("tagline"))
    if not p.get("url") and field("domain"):
        p["url"] = "https://" + field("domain")
    p["site"] = site
    missing = [k for k in ("name", "tagline", "url", "short", "long", "contact_email") if not p.get(k)]
    if missing:
        raise DriverFail(f"{site}: packet is missing {', '.join(missing)}")
    return p


def category(p, driver, default):
    """Per-directory category from the packet's optional `categories` map."""
    return (p.get("categories") or {}).get(driver, default)


def asset(site, name):
    path = ASSETS / site / name
    if not path.exists():
        raise DriverFail(f"asset {path} not found")
    return str(path)


def fit(text, n):
    """Cut text to n characters at a sentence or clause edge."""
    if len(text) <= n:
        return text
    cut = text[:n]
    for sep in (". ", ", with ", ", ", " and ", " "):
        i = cut.rfind(sep)
        if i > n * 0.5:
            return cut[:i].rstrip(".,") + ("." if sep == ". " else "")
    return cut


# Browser

def b(*args, timeout=120):
    cmd = BROWSER + " " + " ".join(shlex.quote(str(a)) for a in args)
    r = subprocess.run(["zsh", "-ic", cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr


def wake():
    """A real click registers only after a screenshot wakes the tab."""
    b("screenshot", "/tmp/dirsub-wake.png")


def snap():
    return b("snapshot", "-i")


def find(snapshot, pattern):
    """Ref of the first line that matches pattern, or None. Use (?:...) groups only."""
    m = re.search(r"^.*?" + pattern + r".*?\[(?:[^\]]*, )?ref=(e\d+)\]", snapshot, re.M)
    return m.group(1) if m else None


def must(snapshot, pattern):
    ref = find(snapshot, pattern)
    if not ref:
        raise DriverFail(f"no element matches {pattern!r}")
    return ref


def line(snapshot, pattern):
    m = re.search(r"^.*?" + pattern + r".*$", snapshot, re.M)
    return m.group(0) if m else ""


def wait_ref(pattern, tries=8, delay=1.5):
    s = ""
    for _ in range(tries):
        s = snap()
        ref = find(s, pattern)
        if ref:
            return ref, s
        time.sleep(delay)
    raise DriverFail(f"element {pattern!r} did not appear")


def fill(snapshot, pattern, value):
    b("fill", "@" + must(snapshot, pattern), value)


def click(ref):
    wake()
    return b("click", "@" + ref)


def final_click(ref):
    """The click that files the form. A dry run fills the form and stops here."""
    if dry_run():
        return False
    click(ref)
    return True


def go(url, wait=5):
    b("open", url)
    time.sleep(wait)
    wake()


def text(n=1500, start=0):
    return b("eval", f"document.body.innerText.slice({start},{start + n})")


def current_url():
    return b("get", "url").strip().split("\n")[-1]


# Mail

def gog(*args):
    """Read Gmail with gog. The mailbox comes from DIRSUB_MAIL_ACCOUNT."""
    account = setting("DIRSUB_MAIL_ACCOUNT")
    for _ in range(6):
        r = subprocess.run(["gog", "-a", account, *args], capture_output=True, text=True)
        if "rateLimit" in r.stdout + r.stderr:
            time.sleep(20)
            continue
        return r.stdout
    raise DriverFail("Gmail API rate limit did not clear")
