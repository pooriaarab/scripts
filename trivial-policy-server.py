#!/usr/bin/env python3
"""trivial-policy-server - an OpenAI-compatible chat endpoint that plays a fixed trivial policy.

Point a benchmark package at it (OPENAI_BASE_URL=http://127.0.0.1:PORT/v1, any API key) and pick the
policy with the model id, for example --model trivial-empty. Free, deterministic, offline.

Policies (model id after "trivial-"):
  empty        an empty answer
  yes          the text "yes"
  ok           the text "OK"
  refuse       "I cannot help with that request."
  echo         the last user message, repeated back
  firsttool    a call to the first tool offered, with empty arguments; plain "done" when no tool is offered
  random       a random word from the last user message (seeded by the request count)
  nulljson     the JSON text {}

Usage: trivial-policy-server.py [--port 8777] [--log requests.jsonl]
"""
import argparse, json, random, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POLICIES = ("empty", "yes", "ok", "refuse", "echo", "firsttool", "random", "nulljson")
STATE = {"n": 0, "log": None}


def last_user(messages):
    for m in reversed(messages or []):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c or ""
    return ""


def reply(policy, body):
    msgs = body.get("messages", [])
    tools = body.get("tools") or []
    if policy == "empty":
        return {"content": ""}
    if policy == "yes":
        return {"content": "yes"}
    if policy == "ok":
        return {"content": "OK"}
    if policy == "refuse":
        return {"content": "I cannot help with that request."}
    if policy == "echo":
        return {"content": last_user(msgs)}
    if policy == "nulljson":
        return {"content": "{}"}
    if policy == "random":
        words = last_user(msgs).split() or ["none"]
        rnd = random.Random(STATE["n"])
        return {"content": rnd.choice(words)}
    if policy == "firsttool":
        if tools:
            name = (tools[0].get("function") or {}).get("name") or "tool"
            return {"content": None, "tool_calls": [{"id": f"call_{STATE['n']}", "type": "function", "function": {"name": name, "arguments": "{}"}}]}
        return {"content": "done"}
    raise ValueError(policy)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._send(200, {"data": [{"id": f"trivial-{p}", "object": "model"} for p in POLICIES]})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, {"error": {"message": "bad json"}})
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._send(404, {"error": {"message": "unknown route"}})
        model = str(body.get("model", ""))
        if not model.startswith("trivial-") or model[len("trivial-"):] not in POLICIES:
            return self._send(400, {"error": {"message": f"unknown policy {model!r}; use one of trivial-" + ", trivial-".join(POLICIES)}})
        STATE["n"] += 1
        policy = model[len("trivial-"):]
        msg = reply(policy, body)
        msg["role"] = "assistant"
        if STATE["log"]:
            STATE["log"].write(json.dumps({"n": STATE["n"], "policy": policy, "keys": sorted(body.keys()), "n_messages": len(body.get("messages", [])), "n_tools": len(body.get("tools") or [])}) + "\n")
            STATE["log"].flush()
        finish = "tool_calls" if msg.get("tool_calls") else "stop"
        self._send(200, {"id": f"trivial-{STATE['n']}", "object": "chat.completion", "created": int(time.time()), "model": model,
                         "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                         "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--log")
    a = ap.parse_args()
    if a.log:
        STATE["log"] = open(a.log, "a")
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    print(f"trivial-policy-server on http://127.0.0.1:{a.port}/v1", file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
