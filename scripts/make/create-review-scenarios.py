#!/usr/bin/env python3
"""Create one Make scenario per module of a custom app, for the app-review form.

Make's public-review form wants a separate scenario URL for EVERY module (plus one
error scenario). Building 32 scenarios by hand is brutal; this creates the shells via
the Scenarios API and prints the URLs to paste into the review form.

IMPORTANT — these are SHELLS. Each has the right module but no connection attached and
has never run. Make's QA opens each scenario and checks it executed SUCCESSFULLY, so
before you submit you still must, in the Make UI:
  1. Create a connection (custom-app connection creation is UI-only — the API returns
     "Failed to load manifest for connection"). Attach it and run each scenario once.
     Read modules (List/Get) run with just the connection; write modules (Create/Publish/
     Delete) need valid data and have real side effects.
  2. Set every module to "visible" (Modules tab).
This script saves the manual scenario-BUILDING; the runs are still yours.

Prereqs
  - The custom app exists and is published. Pass its slug as --app.
  - MAKE_TOKEN with `scenarios:write` and the team's "Create scenarios" permission.
  - The REAL numeric team id (--team) and org id (--org). Get them from the app editor
    URLs, or `GET /api/v2/teams?organizationId=<org>` and `/api/v2/organizations`.
    A wrong/guessed teamId returns `IM002 Insufficient rights`.

Usage
  MAKE_TOKEN=xxxxx python3 create-review-scenarios.py \
      --app my-app-slug --team 36684 --org 92993 --app-json ./app.json \
      [--zone us1.make.com] [--pause 1]

API facts baked in (learned live)
  - POST /api/v2/scenarios?confirmed=true  body {name, teamId, blueprint, scheduling}.
  - blueprint is a JSON *string*; its module ref MUST be `app#{appSlug}:{moduleName}`.
    A bare `{app}:{module}` gives IM007 "module not found"; a `{app}/{module}` fails the
    `^(app#)?.*:.*$` pattern. The `app#` prefix installs the private app into the team
    (that's why `?confirmed=true` is needed).
  - There is a per-org request-rate limit: "Requests limit for organization exceeded"
    (SC-ish). It's generous (~30 rapid) but real — this script paces and retries.
  - Send a normal User-Agent — the default Python-urllib UA is Cloudflare-blocked and
    Make returns `403 error code 1010` (NOT a quota; see publish-app.py).
  - A minted PROD key for the connection: the product's headless signup endpoint can
    give you a throwaway one, e.g. `POST /api/v1/agent/signup {email}` returns an apiKey.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error


def main():
    ap = argparse.ArgumentParser(description="Create one Make scenario per app module")
    ap.add_argument("--app", required=True, help="app slug")
    ap.add_argument("--app-json", required=True, help="path to app.json (for module names/labels)")
    ap.add_argument("--team", required=True, type=int, help="numeric team id (NOT a guess)")
    ap.add_argument("--org", required=True, type=int, help="numeric org id (for the scenario URLs)")
    ap.add_argument("--zone", default="us1.make.com")
    ap.add_argument("--token", default=os.environ.get("MAKE_TOKEN"))
    ap.add_argument("--pause", type=float, default=1.0)
    a = ap.parse_args()
    if not a.token:
        sys.exit("Provide a Make API token via --token or MAKE_TOKEN")

    endpoint = f"https://{a.zone}/api/v2/scenarios?confirmed=true"
    modules = json.load(open(a.app_json)).get("modules", [])

    def create(modname, label):
        blueprint = json.dumps({
            "name": f"CR — {label}",
            "flow": [{"id": 1, "module": f"app#{a.app}:{modname}", "version": 1,
                      "parameters": {}, "mapper": {}, "metadata": {}}],
            "metadata": {"version": 1},
        })
        body = json.dumps({"name": f"CR — {label}", "teamId": a.team, "blueprint": blueprint,
                           "scheduling": json.dumps({"type": "indefinitely", "interval": 900})}).encode()
        for attempt in range(4):
            req = urllib.request.Request(endpoint, data=body, method="POST")
            req.add_header("Authorization", f"Token {a.token}")
            req.add_header("Content-Type", "application/json")
            req.add_header("User-Agent", "curl/8.4.0")
            try:
                with urllib.request.urlopen(req, timeout=25) as r:
                    return json.load(r)["scenario"]["id"]
            except urllib.error.HTTPError as e:
                msg = e.read().decode()[:120]
                if "Requests limit" in msg:
                    print(f"      (org rate limit, backoff 30s)"); time.sleep(30); continue
                return "ERR: " + msg
            except Exception as e:
                return "ERR: " + str(e)
        return "ERR: rate-limited"

    urls = []
    for m in modules:
        time.sleep(a.pause)
        sid = create(m["name"], m["label"])
        if isinstance(sid, int):
            url = f"https://{a.zone}/{a.org}/scenarios/{sid}/edit"
            urls.append((m["label"], url))
            print(f"OK   {m['label']:30} {url}")
        else:
            print(f"FAIL {m['label']:30} {sid}")

    print(f"\nCreated {len(urls)}/{len(modules)} scenarios.")
    print("Paste each into its per-module field on the app's Review form, then attach a "
          "connection + run each once before Request review.")


if __name__ == "__main__":
    main()
