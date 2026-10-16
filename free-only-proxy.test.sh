#!/usr/bin/env bash
# End-to-end test for free-only-proxy. Covers every row marked "tested" in free-only-proxy.failure-modes.md.
# A fake upstream on localhost stands in for OpenRouter. No network, no real key.
set -euo pipefail
cd "$(dirname "$0")"
P=./free-only-proxy.py
T=$(mktemp -d)
UP=8891
PX=8892
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }

cat > "$T/upstream.py" <<'EOF'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = sys.argv[2]
flaky = {"n": 0}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        m = body.get("model", "")
        open(LOG, "a").write(json.dumps({"t": time.time(), "model": m, "max_tokens": body.get("max_tokens"), "reasoning": body.get("reasoning")}) + "\n")
        if m == "flaky:free" and flaky["n"] < 2:
            flaky["n"] += 1
            self.send_response(429); self.send_header("content-length", "2"); self.end_headers(); self.wfile.write(b"{}"); return
        cost = 0.01 if m == "costly:free" else 0
        raw = json.dumps({"choices": [{"message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 3, "completion_tokens": 1, "cost": cost}}).encode()
        self.send_response(200); self.send_header("content-length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 "$T/upstream.py" $UP "$T/up.log" & pids+=($!)
sleep 0.5

start_proxy() { # state daily interval [extra flags]
  OPENROUTER_API_KEY=TESTKEY999 UPSTREAM_BASE_URL=http://127.0.0.1:$UP/v1 FREE_PROXY_RETRY_DELAY=0.05 python3 $P --port $PX --state "$1" --daily "$2" --interval "$3" ${4:-} 2>"$T/proxy.err" &
  PXPID=$!; pids+=($PXPID); sleep 0.6
}
stop_proxy() { kill "$PXPID" 2>/dev/null || true; wait "$PXPID" 2>/dev/null || true; }
post() { # json -> prints http code
  curl -s -o "$T/body" -w '%{http_code}' -X POST http://127.0.0.1:$PX/v1/chat/completions -H 'content-type: application/json' -d "$1"
}

# 9. missing key
if env -u OPENROUTER_API_KEY python3 $P --port 8899 --state "$T/s0" 2>/dev/null; then fail "9 started without a key"; fi
ok "the proxy refuses to start without a key"

start_proxy "$T/s1" 100 0.05
: > "$T/up.log"
# 1. paid model
[ "$(post '{"model":"openai/gpt-5-nano","messages":[{"role":"user","content":"hi"}]}')" = 403 ] || fail "1 paid model not blocked"
grep -q "paid model blocked" "$T/body" || fail "1 message"
[ ! -s "$T/up.log" ] || fail "1 the upstream was contacted for a paid model"
ok "a paid model is blocked and the upstream is never contacted"
# 2. fallback list with a paid id
[ "$(post '{"model":"a:free","models":["a:free","anthropic/claude-haiku-5.5"],"messages":[]}')" = 403 ] || fail "2 fallback not blocked"
[ ! -s "$T/up.log" ] || fail "2 upstream contacted"
ok "a fallback list with a paid model is blocked"
# 3. no model
[ "$(post '{"messages":[]}')" = 400 ] || fail "3 no model"
ok "a request without a model is a 400"
# a free model passes
[ "$(post '{"model":"x/y:free","messages":[{"role":"user","content":"PROMPTMARKER42"}]}')" = 200 ] || fail "free model failed"
ok "a free model is forwarded"
# 10. unknown route
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PX/v1/embeddings -d '{}')" = 404 ] || fail "10 route"
ok "another route is a 404"
# 6. upstream 429 then success
[ "$(post '{"model":"flaky:free","messages":[]}')" = 200 ] || fail "6 retry did not recover"
ok "an upstream 429 is retried and recovers"
# 7. two parallel calls are spaced
stop_proxy
start_proxy "$T/s2" 100 0.4
: > "$T/up.log"
post '{"model":"x/y:free","messages":[]}' >/dev/null & a=$!
post '{"model":"x/y:free","messages":[]}' >/dev/null & b=$!
wait $a $b
python3 - "$T/up.log" <<'EOF'
import json, sys
t = sorted(json.loads(l)["t"] for l in open(sys.argv[1]))
assert len(t) == 2 and t[1] - t[0] >= 0.35, t
EOF
ok "parallel calls reach the upstream spaced by the interval"
stop_proxy

# 4. a free model that reports a cost halts everything
start_proxy "$T/s3" 100 0.05
[ "$(post '{"model":"costly:free","messages":[]}')" = 503 ] || fail "4 cost not halted"
[ -f "$T/s3/STOP" ] || fail "4 no STOP file"
[ "$(post '{"model":"x/y:free","messages":[]}')" = 503 ] || fail "4 later request not halted"
grep -q "STOP" "$T/proxy.err" || fail "4 no message on stderr"
ok "a response with a cost writes STOP and halts every later request"
stop_proxy

# 5. daily limit, kept across a restart
start_proxy "$T/s4" 3 0.05
for i in 1 2 3; do [ "$(post '{"model":"x/y:free","messages":[]}')" = 200 ] || fail "5 call $i"; done
[ "$(post '{"model":"x/y:free","messages":[]}')" = 429 ] || fail "5 limit not reached"
[ -f "$T/s4/DAILY_LIMIT" ] || fail "5 no DAILY_LIMIT"
stop_proxy
start_proxy "$T/s4" 3 0.05
[ "$(post '{"model":"x/y:free","messages":[]}')" = 429 ] || fail "5 the count was lost on restart"
ok "the daily limit answers 429, writes DAILY_LIMIT and survives a restart"
stop_proxy

# 12. output cap and reasoning effort are applied to every request
start_proxy "$T/s5" 100 0.05 "--max-tokens 512 --reasoning-effort low"
: > "$T/up.log"
post '{"model":"x/y:free","messages":[]}' >/dev/null
post '{"model":"x/y:free","messages":[],"max_tokens":100}' >/dev/null
post '{"model":"x/y:free","messages":[],"max_completion_tokens":9000}' >/dev/null
python3 - "$T/up.log" <<'EOF'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert [x["max_tokens"] for x in r] == [512, 100, 512], r
assert all(x["reasoning"] == {"effort": "low"} for x in r), r
EOF
ok "the output cap keeps a smaller request limit, lowers a larger one, and sets the reasoning effort"
stop_proxy

# 8. no key and no prompt in any file
if grep -rq "TESTKEY999" "$T/s1" "$T/s2" "$T/s3" "$T/s4"; then fail "8 the key reached the state files"; fi
if grep -rq "PROMPTMARKER42" "$T/s1" "$T/s2" "$T/s3" "$T/s4"; then fail "8 a prompt reached the log"; fi
ok "the log and the state hold neither the key nor a prompt"

echo "all $pass checks passed"
