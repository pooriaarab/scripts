#!/usr/bin/env bash
# End-to-end test for trivial-policy-server. Covers every row marked "tested" in
# trivial-policy-server.failure-modes.md. Localhost only.
set -euo pipefail
cd "$(dirname "$0")"
PORT=8893
python3 ./trivial-policy-server.py --port $PORT 2>/dev/null &
SP=$!
trap 'kill $SP 2>/dev/null || true' EXIT
sleep 0.7
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }
call() { curl -s -w '\n%{http_code}' -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'content-type: application/json' -d "$1"; }
field() { python3 -c "import sys,json;d=json.loads(sys.stdin.read().rstrip('\n').rsplit('\n',1)[0]);print(eval(sys.argv[1]))" "$1"; }
code() { tail -n1; }

r=$(call '{"model":"gpt-4","messages":[]}'); [ "$(echo "$r" | code)" = 400 ] || fail "1 unknown model"
echo "$r" | grep -q "trivial-empty" || fail "1 no list of policies"
r=$(call '{"model":"trivial-nope","messages":[]}'); [ "$(echo "$r" | code)" = 400 ] || fail "1 unknown policy"
ok "an unknown model or policy is a 400 that lists the policies"

r=$(curl -s -w '\n%{http_code}' -X POST http://127.0.0.1:$PORT/v1/chat/completions -d 'not json'); [ "$(echo "$r" | code)" = 400 ] || fail "2 bad json"
ok "a body that is not JSON is a 400"

r=$(curl -s -w '\n%{http_code}' -X POST http://127.0.0.1:$PORT/v1/embeddings -d '{}'); [ "$(echo "$r" | code)" = 404 ] || fail "3 route"
ok "another route is a 404"

r=$(call '{"model":"trivial-firsttool","messages":[{"role":"user","content":"hi"}]}')
[ "$(echo "$r" | field "d['choices'][0]['message']['content']")" = done ] || fail "4 no tool offered"
ok "firsttool with no tool offered answers plain text"

r=$(call '{"model":"trivial-firsttool","messages":[],"tools":[{"type":"function","function":{"name":"lookup","parameters":{}}},{"type":"function","function":{"name":"pay"}}]}')
[ "$(echo "$r" | field "d['choices'][0]['message']['tool_calls'][0]['function']['name']")" = lookup ] || fail "5 first tool"
[ "$(echo "$r" | field "d['choices'][0]['finish_reason']")" = tool_calls ] || fail "5 finish reason"
ok "firsttool calls the first tool with empty arguments"

r=$(call '{"model":"trivial-echo","messages":[{"role":"user","content":[{"type":"text","text":"alpha"},{"type":"text","text":"beta"}]}]}')
[ "$(echo "$r" | field "d['choices'][0]['message']['content']")" = "alpha beta" ] || fail "6 parts"
ok "echo joins the text parts of a message"

a=$(call '{"model":"trivial-random","messages":[{"role":"user","content":"one two three four five six seven"}]}' | field "d['choices'][0]['message']['content']")
b=$(call '{"model":"trivial-random","messages":[{"role":"user","content":"one two three four five six seven"}]}' | field "d['choices'][0]['message']['content']")
kill $SP; wait $SP 2>/dev/null || true
python3 ./trivial-policy-server.py --port $PORT 2>/dev/null & SP=$!
sleep 0.7
a2=$(call '{"model":"trivial-random","messages":[{"role":"user","content":"one two three four five six seven"}]}' | field "d['choices'][0]['message']['content']")
[ "$a" = "$a2" ] || fail "7 the first random answer changed after a restart ($a vs $a2)"
ok "random depends on the request count, so a full run is repeatable"

echo "all $pass checks passed"
