#!/usr/bin/env python3
"""free-only-proxy - an OpenAI-compatible proxy that can only reach free OpenRouter models.

  OPENROUTER_API_KEY=... free-only-proxy.py [--port 8790] [--state DIR] [--daily 900] [--interval 3.5]
                                            [--max-tokens N] [--reasoning-effort low|medium|high]

Point a benchmark package at it: OPENAI_BASE_URL=http://127.0.0.1:8790/v1, any API key.
Refuses every model id that does not end in ":free". Spaces upstream calls by --interval seconds.
Counts requests per UTC day in DIR/count.json; at --daily it answers 429 and writes DIR/DAILY_LIMIT.
If a response reports a nonzero usage.cost, it writes DIR/STOP and answers 503 from then on.
--max-tokens caps the output length of every request (a request asking for less keeps its own limit).
--reasoning-effort sets the reasoning effort of every request, so all models share one setting.
Env for tests: UPSTREAM_BASE_URL (default https://openrouter.ai/api/v1).
"""
import argparse, datetime, json, os, sys, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG = {}
LOCK = threading.Lock()
LAST = [0.0]


def day():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def read_count():
    p = os.path.join(CFG["state"], "count.json")
    try:
        d = json.load(open(p))
        return d["count"] if d["day"] == day() else 0
    except Exception:
        return 0


def write_count(n):
    json.dump({"day": day(), "count": n}, open(os.path.join(CFG["state"], "count.json"), "w"))


def log(entry):
    entry["t"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with open(os.path.join(CFG["state"], "requests.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")


def free_ids(body):
    ids = []
    if body.get("model"):
        ids.append(body["model"])
    if isinstance(body.get("models"), list):
        ids += body["models"]
    return ids


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj, headers=None):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.send(200, {"data": []})
        self.send(404, {"error": {"message": "unknown route"}})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.send(404, {"error": {"message": "unknown route"}})
        n = int(self.headers.get("content-length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self.send(400, {"error": {"message": "bad json"}})
        ids = free_ids(body)
        if not ids:
            return self.send(400, {"error": {"message": "no model in the request"}})
        if os.path.isfile(os.path.join(CFG["state"], "STOP")):
            return self.send(503, {"error": {"message": "STOP: a response reported a cost; the run is halted"}})
        bad = [i for i in ids if not str(i).endswith(":free")]
        if bad:
            log({"model": bad[0], "status": 403, "note": "paid model blocked"})
            return self.send(403, {"error": {"message": f"paid model blocked: {bad[0]!r}; only ids ending in ':free' are allowed"}})
        if CFG.get("max_tokens"):
            asked = body.pop("max_completion_tokens", None) or body.get("max_tokens")
            body["max_tokens"] = min(int(asked), CFG["max_tokens"]) if asked else CFG["max_tokens"]
        if CFG.get("effort"):
            body["reasoning"] = {"effort": CFG["effort"]}
        with LOCK:
            if read_count() >= CFG["daily"]:
                open(os.path.join(CFG["state"], "DAILY_LIMIT"), "w").write(day() + "\n")
                log({"model": ids[0], "status": 429, "note": "daily limit"})
                return self.send(429, {"error": {"message": "daily request limit reached"}}, {"Retry-After": "3600"})
            wait = CFG["interval"] - (time.time() - LAST[0])
            if wait > 0:
                time.sleep(wait)
            LAST[0] = time.time()
            write_count(read_count() + 1)
            status, resp, hdrs = self.upstream(body)
        cost = 0
        try:
            cost = float((resp.get("usage") or {}).get("cost") or 0)
        except Exception:
            pass
        u = resp.get("usage") or {}
        log({"model": ids[0], "status": status, "in": u.get("prompt_tokens"), "out": u.get("completion_tokens"), "cost": cost})
        if cost > 0:
            open(os.path.join(CFG["state"], "STOP"), "w").write(f"cost {cost} on {ids[0]}\n")
            print(f"free-only-proxy: STOP, a response reported cost {cost} on {ids[0]}", file=sys.stderr, flush=True)
            return self.send(503, {"error": {"message": "STOP: a response reported a cost"}})
        self.send(status, resp, hdrs)

    def upstream(self, body):
        url = CFG["upstream"].rstrip("/") + "/chat/completions"
        data = json.dumps(body).encode()
        delay = float(os.environ.get("FREE_PROXY_RETRY_DELAY", "2"))
        for attempt in range(4):
            req = urllib.request.Request(url, data=data, method="POST", headers={"Authorization": "Bearer " + CFG["key"], "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    return r.status, json.loads(r.read() or b"{}"), {}
            except urllib.error.HTTPError as e:
                txt = e.read()
                try:
                    obj = json.loads(txt)
                except Exception:
                    obj = {"error": {"message": txt[:200].decode("utf8", "ignore")}}
                if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                    ra = e.headers.get("Retry-After")
                    time.sleep(min(float(ra), 60) if ra and ra.replace(".", "").isdigit() else delay)
                    delay *= 2
                    continue
                return e.code, obj, {}
            except Exception as e:
                if attempt < 3:
                    time.sleep(delay)
                    delay *= 2
                    continue
                return 502, {"error": {"message": f"upstream unreachable: {type(e).__name__}"}}, {}
        return 502, {"error": {"message": "unreachable"}}, {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--state", default="free-proxy-state")
    ap.add_argument("--daily", type=int, default=900)
    ap.add_argument("--interval", type=float, default=3.5)
    ap.add_argument("--max-tokens", type=int, default=0)
    ap.add_argument("--reasoning-effort", default="")
    a = ap.parse_args()
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        print("free-only-proxy: OPENROUTER_API_KEY is not set", file=sys.stderr)
        sys.exit(2)
    os.makedirs(a.state, exist_ok=True)
    CFG.update({"key": key, "state": a.state, "daily": a.daily, "interval": a.interval, "max_tokens": a.max_tokens, "effort": a.reasoning_effort, "upstream": os.environ.get("UPSTREAM_BASE_URL", "https://openrouter.ai/api/v1")})
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    print(f"free-only-proxy on http://127.0.0.1:{a.port}/v1 (daily {a.daily}, interval {a.interval}s)", file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
