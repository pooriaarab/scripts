#!/usr/bin/env python3
"""Publish a Make (Integromat) custom app from a bundled app.json via the SDK API.

Make has NO whole-app.json import. A custom app is stored as separate components
(base, connections, webhooks, modules, remote procedures). This tool pushes a bundled
app.json — top-level keys `base`, `connection`, `modules[]`, `webhooks[]`, `rpcs[]` —
to a live app over the SDK Apps API, instead of pasting each section by hand.

Prereqs
  - The app already exists in Make (create the shell in the UI: More -> Custom apps
    -> Create custom app). Pass its slug as --app.
  - A Make API token with scopes `sdk-apps:read` + `sdk-apps:write`
    (Profile -> API/Access -> Add token). Pass via --token or env MAKE_TOKEN.
  - A connection already created on the app (the tool reuses the first one, or pass
    --connection <name>). Create it once in the UI if missing.

Usage
  MAKE_TOKEN=xxxxx python3 publish-app.py \
      --app my-app-slug --app-json ./app.json [--version 1] [--zone us1.make.com] \
      [--connection my-conn] [--pause 1.5] [--dry-run]

app.json shape (per component)
  base:        { baseUrl, headers, log }
  connection:  { label, type, parameters[], communication, log }   # reused, not recreated
  modules[]:   { name, label, description, kind, connection?, webhook?, communication,
                 parameters[], interface[], samples[] }
                 kind in {action, search, instant_trigger}; name "makeApiCall" -> universal
  webhooks[]:  { name, label, type, parameters[], attach{url,method,body,response}, detach{...} }
  rpcs[]:      { name, label, communication }

API facts baked in (learned the hard way, 2026-08)
  - Base:        https://{zone}/api/v2/sdk/apps
  - Auth header: `Authorization: Token <token>`
  - Modules & RPCs are VERSIONED:   /apps/{app}/{ver}/modules , /rpcs
  - Webhooks are UNVERSIONED:        /apps/{app}/webhooks  (create)
    and webhook sections live at:    /apps/webhooks/{webhookName}/{section}
  - Connections are UNVERSIONED:     /apps/{app}/connections
  - Module create: POST .../modules {name, typeId, label, description,
      connection|webhook, moduleInitMode:"blank"}. typeId: 1=trigger(poll), 4=action,
      9=search, 10=instant-trigger(converger), 11=responder, 12=universal(returner).
  - Section set: PUT .../modules/{name}/{api|expect|interface|samples|parameters|scope}
      body = the raw section JSON. api<-communication, expect<-mappable parameters.
  - QUOTA (not a per-second rate limit): HTTP 403 body code `1010` = the SDK write
      quota is drained. It's a WINDOWED bucket — isolated calls and short bursts (20+
      rapid) succeed, but big back-to-back runs (100s of calls) exhaust it, and then
      it needs a LONG cooldown (~30-60 min of NO calls) to refill. Lowering --pause or
      retrying in a loop does NOT help — a retry-storm keeps hammering the empty bucket
      and holds it empty. This script aborts on a persistent 1010 with guidance; just
      wait and re-run (it's idempotent and resumes where it left off). Every failed
      call still counts, so don't test against a live app more than you have to.
  - Connection/webhook auth quirk: attach/detach reference connection params as
      {{account.paramName}} (NOT {{connection.*}}), and do NOT inherit base — so this
      tool writes attach/detach with an ABSOLUTE url + explicit account Bearer header.
  - Webhook incoming `communication` does not see the connection; a minimal
      {"output":"{{body}}"} emits the payload to the paired instant-trigger module.
  - Make auto-names created webhooks (often after the app slug); the tool captures the
      real name from the create response and links instant-trigger modules to it.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error

TYPEID = {"action": 4, "search": 9, "instant_trigger": 10, "universal": 12}


def main():
    ap = argparse.ArgumentParser(description="Publish a Make custom app from app.json")
    ap.add_argument("--app", required=True, help="app slug (e.g. content-rabbit-xvboes)")
    ap.add_argument("--app-json", required=True, help="path to bundled app.json")
    ap.add_argument("--version", default="1")
    ap.add_argument("--zone", default="us1.make.com", help="Make zone host (us1/eu1/...)")
    ap.add_argument("--token", default=os.environ.get("MAKE_TOKEN"))
    ap.add_argument("--connection", default=None, help="connection name (default: first on app)")
    ap.add_argument("--pause", type=float, default=1.5, help="seconds between API calls")
    ap.add_argument("--push-base", action="store_true", help="also PATCH the base section")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.token:
        sys.exit("Provide a Make API token via --token or MAKE_TOKEN")

    API = f"https://{a.zone}/api/v2/sdk/apps"
    VROOT = f"{API}/{a.app}/{a.version}"     # modules, rpcs, base
    UROOT = f"{API}/{a.app}"                 # webhooks, connections
    d = json.load(open(a.app_json))
    baseurl = (d.get("base", {}) or {}).get("baseUrl", "").rstrip("/")

    def _once(method, url, body):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Token {a.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read() or "{}")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()[:200]
        except Exception as e:
            return 0, str(e)

    def call(method, url, body=None):
        # `1010` is Make's SDK QUOTA error, not a per-second rate limit. Isolated
        # calls succeed; it's a windowed bucket that big back-to-back runs drain. A
        # retry-STORM makes it worse — it keeps hammering an empty bucket, which
        # holds it empty. So: one short backoff+retry for a transient blip, then
        # ABORT with guidance. The script is idempotent, so re-running after the
        # window resets (~30-60 min of NO calls) picks up exactly where it left off.
        if a.dry_run and method != "GET":
            print(f"      DRY {method} {url.split('/api/')[-1]}")
            return 200, {}
        time.sleep(a.pause)
        st, r = _once(method, url, body)
        if st == 403 and isinstance(r, str) and "1010" in r:
            print("      (1010 quota hit — one 20s backoff, then retry)")
            time.sleep(20)
            st, r = _once(method, url, body)
            if st == 403 and isinstance(r, str) and "1010" in r:
                print(
                    "\nABORTING: Make SDK quota (1010) is drained.\n"
                    "This is a windowed quota, not a pacing problem — do NOT lower --pause\n"
                    "or retry in a loop (that keeps it empty). Stop all calls, wait ~30-60\n"
                    "min for the window to reset, then re-run this exact command. It skips\n"
                    "whatever already exists and continues from there.", flush=True)
                sys.exit(2)
        return st, r

    def names(url, key):
        st, r = call("GET", url)
        return {i["name"] for i in r.get(key, [])} if st == 200 and isinstance(r, dict) else set()

    def put(url, section, payload):
        st, r = call("PUT", f"{url}/{section}", payload)
        print(f"      {section:10} {st} {'ok' if st in (200,201) else r}")

    # connection
    conn = a.connection
    if not conn:
        st, r = call("GET", f"{UROOT}/connections")
        cs = r.get("appConnections", []) if isinstance(r, dict) else []
        conn = cs[0]["name"] if cs else None
    print(f"[app {a.app} v{a.version}] connection = {conn}")

    if a.push_base and d.get("base"):
        st, r = call("PATCH", f"{VROOT}/base", d["base"])
        print(f"[base] PATCH -> {st} {'' if st in (200,201) else r}")

    # webhooks (unversioned)
    wh_map = {}
    st, r = call("GET", f"{UROOT}/webhooks")
    existing_wh = {x.get("label"): x["name"] for x in r.get("appWebhooks", [])} if isinstance(r, dict) else {}
    for w in d.get("webhooks", []):
        label = w["label"]
        if label in existing_wh:
            real = existing_wh[label]
            print(f"[webhook] {w['name']} exists as '{real}' — reuse")
        else:
            st, r = call("POST", f"{UROOT}/webhooks", {"type": w.get("type", "web"), "label": label, "connection": conn})
            real = r.get("appWebhook", {}).get("name") if isinstance(r, dict) else None
            print(f"[webhook] create {w['name']} -> {st} name='{real}'")
            if not real:
                continue
        wh_map[w["name"]] = real
        wsec = f"{API}/webhooks/{real}"
        attach = {"url": f"{baseurl}{w['attach']['url']}", "method": w["attach"].get("method", "POST"),
                  "headers": {"Authorization": "Bearer {{account.apiKey}}", "Accept": "application/json", "Content-Type": "application/json"},
                  "body": w["attach"].get("body", {}),
                  "response": w["attach"].get("response", {})}
        detach = {"url": f"{baseurl}{w['detach']['url']}", "method": w["detach"].get("method", "DELETE"),
                  "headers": {"Authorization": "Bearer {{account.apiKey}}", "Accept": "application/json"}}
        put(wsec, "attach", attach)
        put(wsec, "detach", detach)
        put(wsec, "api", {"output": "{{body}}"})
        put(wsec, "parameters", w.get("parameters", []))

    # modules (versioned)
    existing_mod = names(f"{VROOT}/modules", "appModules")
    for m in d.get("modules", []):
        name, kind = m["name"], m["kind"]
        if name in existing_mod:
            print(f"[module] {name} exists — skip"); continue
        tid = 12 if name == "makeApiCall" else TYPEID[kind]
        body = {"name": name, "typeId": tid, "label": m["label"], "description": m["description"], "moduleInitMode": "blank"}
        if kind == "instant_trigger":
            body["webhook"] = wh_map.get(m.get("webhook"))
        else:
            body["connection"] = conn
        st, r = call("POST", f"{VROOT}/modules", body)
        print(f"[module] {name} ({kind}/{tid}) -> {st} {'' if st in (200,201) else r}")
        if st not in (200, 201):
            continue
        murl = f"{VROOT}/modules/{name}"
        if m.get("communication") and kind != "instant_trigger":
            put(murl, "api", m["communication"])
        if m.get("parameters"):
            put(murl, "expect", m["parameters"])
        if m.get("interface"):
            put(murl, "interface", m["interface"])
        if m.get("samples"):
            s = m["samples"][0] if isinstance(m["samples"], list) and m["samples"] else m["samples"]
            put(murl, "samples", s)

    # rpcs (versioned; absolute url + auth header since they may not inherit base)
    existing_rpc = names(f"{VROOT}/rpcs", "appRpcs")
    for rp in d.get("rpcs", []):
        name = rp["name"]
        if name in existing_rpc:
            print(f"[rpc] {name} exists — skip"); continue
        st, r = call("POST", f"{VROOT}/rpcs", {"name": name, "label": rp["label"], "connection": conn})
        print(f"[rpc] {name} -> {st} {'' if st in (200,201) else r}")
        if st not in (200, 201):
            continue
        comm = dict(rp["communication"])
        if comm.get("url", "").startswith("/"):
            comm["url"] = baseurl + comm["url"]
        comm.setdefault("headers", {})["Authorization"] = "Bearer {{connection.apiKey}}"
        put(f"{VROOT}/rpcs/{name}", "api", comm)

    print("\nDONE.")


if __name__ == "__main__":
    main()
