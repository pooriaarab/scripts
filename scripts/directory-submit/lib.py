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


def refs(snapshot, pattern):
    """Refs of every line that matches pattern, in page order. For fields with no accessible name."""
    out = []
    for ln in snapshot.split("\n"):
        m = re.search(r"ref=(e\d+)", ln)
        if m and re.search(pattern, ln):
            out.append(m.group(1))
    return out


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


def select(index, label):
    """Pick an option of the index-th <select> by its text or value, with the native setter
    and real events, so a React form sees it. Raises if the page does not hold it afterwards."""
    js = ("(()=>{const s=document.querySelectorAll('select')[%d];const L=%s;"
          "const o=[...s.options].find(o=>o.textContent.trim()===L||o.value===L);if(!o)return 'NO-OPTION';"
          "Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(s,o.value);"
          "s.dispatchEvent(new Event('input',{bubbles:true}));s.dispatchEvent(new Event('change',{bubbles:true}));"
          "return 'OK:'+s.value})()") % (index, json.dumps(label))
    out = b("eval", js)
    if "OK:" not in out:
        raise DriverFail(f"select {index} did not take {label!r}: {out.strip()[:80]}")


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


def ev(js):
    """Run JavaScript on the page. Returns the decoded result, with the tool's status lines removed."""
    out = "\n".join(l for l in b("eval", js).split("\n") if not l.startswith("✓")).strip()
    try:
        return json.loads(out)
    except ValueError:
        return out


def text(n=1500, start=0):
    return str(ev(f"document.body.innerText.slice({start},{start + n})"))


def say(page, n=140):
    """One line of page text, for a proof or reason column."""
    return " ".join(page.split())[:n]


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


def newest_message(query):
    """Text of the newest message of the newest thread for a query, or ''. Mail with the same subject
    joins one thread, so the last message of that thread is the new one."""
    try:
        threads = json.loads(gog("--gmail-no-send", "gmail", "search", query, "--max", "1", "--json")).get("threads", [])
    except ValueError:
        return ""
    if not threads:
        return ""
    body = gog("--gmail-no-send", "gmail", "thread", "get", threads[0]["id"], "--full")
    return body.split("=== Message ")[-1]


def mail_link(query, pattern, before, tries=20, delay=6):
    """First URL that matches pattern in the newest message for a Gmail query, once the message count
    passes `before` (take mail_count(query) before the action that sends the mail).
    Never prints the URL: it may hold a token."""
    for _ in range(tries):
        if mail_count(query) > before:
            for url in re.findall(r"https?://[^\s<>\"')\]]+", newest_message(query)):
                if re.search(pattern, url):
                    return url
        time.sleep(delay)
    raise DriverFail(f"no new mail for {query!r} with a link matching {pattern!r}")


# Accounts

ACCOUNTS_FILE = Path(os.environ.get("DIRSUB_ACCOUNTS", "~/.secrets/directory-submission-accounts.env")).expanduser()


def account(board):
    """(email, password) for a board. The first call makes a random password and saves a
    `board|email|password` line in ACCOUNTS_FILE (mode 0600). Nothing here prints a password."""
    import secrets
    import string
    if ACCOUNTS_FILE.exists():
        for ln in ACCOUNTS_FILE.read_text().splitlines():
            name, _, rest = ln.partition("|")
            email, _, pw = rest.partition("|")
            if name == board and pw:
                return email, pw
    alphabet = string.ascii_letters + string.digits
    pw = "".join(secrets.choice(alphabet) for _ in range(18)) + "!7"
    fd = os.open(ACCOUNTS_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, f"{board}|{CONTACT_EMAIL}|{pw}\n".encode())
    os.close(fd)
    return CONTACT_EMAIL, pw


def type_secret(ref, value):
    """Fill a password field. The value goes to the browser and is never echoed."""
    r = subprocess.run(["zsh", "-ic", f"{BROWSER} fill @{ref} {shlex.quote(value)}"], capture_output=True, text=True)
    if "Done" not in r.stdout:
        raise DriverFail("password field did not take the value")


def mail_count(query):
    """Number of messages in all threads that match a query. A new mail with the same subject joins
    an old thread, so compare this count before and after an action instead of thread ids."""
    try:
        threads = json.loads(gog("--gmail-no-send", "gmail", "search", query, "--max", "20", "--json")).get("threads", [])
    except ValueError:
        return -1
    return sum(t.get("messageCount", 1) for t in threads)


def mail_pin(query, pattern, before, tries=20, delay=6):
    """First match of the regex `pattern` (group 1) in the newest message for a query: a verification
    PIN or code. Waits until mail_count(query) passes `before`."""
    for _ in range(tries):
        if mail_count(query) > before:
            m = re.search(pattern, newest_message(query), re.S)
            if m:
                return m.group(1)
        time.sleep(delay)
    raise DriverFail(f"no new mail for {query!r} with a code matching {pattern!r}")


def set_text(selector, value):
    """Set a textarea or input by CSS selector with the native setter and real events. For multi-line values."""
    js = ("(()=>{const e=document.querySelector(%s);if(!e)return 'NO-EL';const P=e.tagName==='TEXTAREA'?HTMLTextAreaElement:HTMLInputElement;"
          "Object.getOwnPropertyDescriptor(P.prototype,'value').set.call(e,%s);e.dispatchEvent(new Event('input',{bubbles:true}));"
          "e.dispatchEvent(new Event('change',{bubbles:true}));return 'OK'})()") % (json.dumps(selector), json.dumps(value))
    out = b("eval", js)
    if "OK" not in out:
        raise DriverFail(f"set_text {selector}: {out.strip()[:60]}")


def dismiss_cookies():
    """Close a cookie banner that covers the page. Prefers Decline, else Reject, else Accept necessary."""
    s = snap()
    for pat in (r'button "(?:Decline|Reject all|Reject|decline|Only necessary|Necessary only)"', r'button "(?:Accept|accept|Got it|OK)"'):
        ref = find(s, pat)
        if ref:
            b("click", "@" + ref)
            time.sleep(1)
            return True
    return False


def html_link(query, pattern, before, tries=20, delay=6):
    """Like mail_link, but reads hrefs from the HTML part of the newest thread (for mail whose button link is not in the text)."""
    import base64
    for _ in range(tries):
        if mail_count(query) > before:
            try:
                threads = json.loads(gog("--gmail-no-send", "gmail", "search", query, "--max", "1", "--json")).get("threads", [])
                raw = gog("--gmail-no-send", "gmail", "thread", "get", threads[0]["id"], "--full", "--json")
                j = json.loads(raw)
            except (ValueError, IndexError, KeyError):
                time.sleep(delay)
                continue
            parts = []

            def walk(o):
                if isinstance(o, dict):
                    for k, v in o.items():
                        if k == "data" and isinstance(v, str) and len(v) > 40:
                            try:
                                parts.append(base64.urlsafe_b64decode(v + "=" * (-len(v) % 4)).decode("utf8", "ignore"))
                            except Exception:
                                pass
                        else:
                            walk(v)
                elif isinstance(o, list):
                    for v in o:
                        walk(v)
            walk(j)
            html = "\n".join(parts)
            urls = [u.replace("&amp;", "&") for u in re.findall(r'href=["\']([^"\']+)["\']', html)]
            # the newest message is last in the thread; prefer the last match
            hits = [u for u in urls if re.search(pattern, u)]
            if hits:
                return hits[-1]
        time.sleep(delay)
    raise DriverFail(f"no new mail for {query!r} with an href matching {pattern!r}")


def select_opt(label):
    """Pick the option `label` in whichever native select holds it, with the native setter and real events."""
    js = ("(()=>{const L=%s;for(const s of document.querySelectorAll('select')){const o=[...s.options].find(o=>o.textContent.trim()===L||o.value===L);"
          "if(!o)continue;Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(s,o.value);"
          "s.dispatchEvent(new Event('input',{bubbles:true}));s.dispatchEvent(new Event('change',{bubbles:true}));return 'OK:'+s.value}return 'NO-OPTION'})()") % json.dumps(label)
    out = b("eval", js)
    if "OK:" not in out:
        raise DriverFail(f"no select holds {label!r}: {out.strip()[:80]}")
