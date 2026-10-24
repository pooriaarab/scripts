"""Helpers for round 6 drivers: one generic form filler for boards with a plain submit form."""
import time

from drivers.common import FLEET, TOPIC
from lib import (current_url, CONTACT_EMAIL, DriverFail, RateLimited, Result, b, click, fill, final_click, find, fit, go, must, refs,
                 say, select, setting, snap, text)

MAKER = None


def values(p):
    """Every value a plain form may ask for, taken from the packet."""
    try:
        maker = setting("DIRSUB_MAKER_NAME")
    except DriverFail:
        maker = "Pooria Arab"
    return {
        "name": p["name"], "url": p["url"], "tagline": fit(p["tagline"], 100), "short": fit(p["short"], 250),
        "long": p["long"], "email": CONTACT_EMAIL, "site_email": p["contact_email"], "maker": maker,
        "company": p.get("name"), "tags": ", ".join((p.get("tags") or [])[:6]),
        "domain": p["url"].split("//")[-1], "repo": p.get("repo", ""),
        "features": "Search listings by place and category\nFree REST API and MCP server\nSources cited on every listing",
        "features_line": "Search by place and category, free REST API and MCP server, sources cited on every listing",
    }


def generic(site, p, url, fields, submit, ok, bad=(), wait=5, pre=None, selects=(), gap=1, post=None, limit=None, live=None,
            clicks=(), after=None):
    """Open url, fill each (pattern, key) pair, click the submit button, read the result.

    fields: list of (regex for the snapshot line, key into values(p) or a literal str starting with '=').
    selects: list of (regex for the combobox line, option text) set through the browser select command.
    ok: regex that proves success in the page text. bad: regexes that raise DriverFail with the page text.
    limit: regex in the page text that means rate limited.
    """
    import re
    v = values(p)
    b("open", "about:blank")
    time.sleep(1)
    go(url, wait=wait)
    if pre:
        pre(v)
    s = snap()
    for pattern, key in fields:
        optional = key.startswith("?")
        key = key[1:] if optional else key
        val = key[1:] if key.startswith("=") else v[key]
        ref = find(s, pattern)
        if not ref:
            if optional:
                continue
            raise DriverFail(f"no field matches {pattern!r}")
        b("fill", "@" + ref, val)
    for pattern, option in selects:
        s = snap()
        ref = refs(s, r"combobox")[int(pattern[1:])] if pattern.startswith("@") else must(s, pattern)
        if option == "*first":
            opts = options_of(s, ref)
            opt = next((o for o in opts if not re.match(r"(?i)(select|pick|choose|—|-)", o)), None)
            if not opt:
                raise DriverFail("no real option in " + repr(opts[:10]))
        elif isinstance(option, dict):
            opts = options_of(s, ref)
            opt = None
            for kw in option.get(site, []) + option.get(KIND[site], []) + option.get("other", []):
                opt = next((o for o in opts if kw.lower() in o.lower()), None)
                if opt:
                    break
            if not opt:
                raise DriverFail("no option for " + KIND[site] + " in " + repr(opts[:40]))
        else:
            opt = option(site, p) if callable(option) else option
        b("select", "@" + ref, opt)
    for pattern in clicks:
        click(must(snap(), pattern))
        time.sleep(1)
    time.sleep(gap)
    if post:
        post()
    s = snap()
    ref = find(s, submit)
    if not ref:
        raise DriverFail(f"no submit button {submit!r}")
    if re.search(r"disabled", next((l for l in s.split("\n") if f"ref={ref}]" in l), "")):
        raise DriverFail("submit button is disabled")
    before = text(3000)
    if not final_click(ref):
        return Result("skipped", "dry run")
    time.sleep(4)
    if after:
        after()
    time.sleep(3)
    page = text(3000)
    lm = re.search(limit, page, re.I) if limit else None
    if re.search(r"err=limited|too_many|429", current_url()):
        raise RateLimited("board answered " + current_url().split("//")[1][:80])
    if lm:
        a = page.rfind("\n", 0, lm.start()) + 1
        raise RateLimited(say(page[a:page.find("\n", lm.end())], 120))
    def line_of(x):
        a = page.rfind("\n", 0, x.start()) + 1
        e = page.find("\n", x.end())
        return page[a:e if e > 0 else None].strip().lower()

    for pat in bad:
        if re.search(pat, page, re.I) and not re.search(pat, before, re.I):
            raise DriverFail("board said: " + say(re.search(pat, page, re.I).group(0), 200))
    before_lines = {l.strip().lower() for l in before.split("\n")}
    m = next((x for x in re.finditer(ok, page, re.I | re.S) if line_of(x) not in before_lines), None)
    if m:
        start = page.rfind("\n", 0, m.start()) + 1
        end = page.find("\n", m.end())
        said = say(page[start:end if end > 0 else None], 150)
        host = url.split("//")[1].split("/")[0]
        status = "live" if live and re.search(live, page, re.I) else "submitted"
        return Result(status, f"{host}: '{said}'")
    for pat in bad:
        if re.search(pat, page, re.I):
            raise DriverFail(say(page, 300))
    raise DriverFail("no confirmation: " + say(page, 250))


KIND = {
    "agentsandboxes": "dev", "agentwalletindex": "finance", "creditunions": "finance", "datingcoaches": "social",
    "doulas": "health", "drivingschool": "education", "eatingdisorder": "health", "fertilityclinics": "health",
    "foreclosurelistings": "realestate", "french4pr": "education", "immigrationhelp": "education",
    "peptideclinic": "health", "petcremation": "other", "psilocybincenters": "health", "robotaxis": "transport",
    "soberbars": "social", "auctionfinder": "ecommerce",
}


def pick(table, default=None):
    """Return a callable (site, p) -> option text from a dict keyed by kind."""
    return lambda site, p: table.get(KIND[site], default or table["other"])


def options_of(snapshot, ref):
    """Option texts that follow the combobox line with this ref in a snapshot."""
    import re
    out, on = [], False
    for ln in snapshot.split("\n"):
        if f"ref={ref}]" in ln and "combobox" in ln:
            on = True
            continue
        if on:
            m = re.match(r'\s+- option "(.*?)"(?: \[|$)', ln)
            if m:
                out.append(m.group(1))
            else:
                break
    return out


def cat_for(site, table):
    """Option keywords for a site from a dict keyed by KIND, falling back to 'other'."""
    k = KIND[site]
    return table.get(k) or table.get(site) or table["other"]


def long_text(p, words=170):
    """A description of at least `words` words: the packet text plus a factual paragraph that fits every fleet site."""
    extra = (" How it works: each listing is one entry with its own page. Facts such as place, category, status and "
             "source links sit on that page, and every claim names where it came from so a reader can check it. "
             "The same data is open to programs: a free REST API and an MCP server answer queries with no key and no "
             "sign-up, so an AI assistant can look things up directly. The directory is free to browse and free to use. "
             "It is built and maintained by Beeloud, an independent studio that makes niche directories. Listings are "
             "added from public sources and from owner submissions, and a thin or incomplete page is kept out of "
             "search results until it holds enough checked facts to be useful.")
    t = p["long"] + extra
    return t
