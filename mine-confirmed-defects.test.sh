#!/usr/bin/env bash
# Offline tests for mine-confirmed-defects. Stub gh on PATH.
set -uo pipefail
fail=0; pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }
SCRIPT="$(cd "$(dirname "$0")" && pwd)/mine-confirmed-defects"
FAKE_ROOT=$(mktemp -d)
FAKE_BIN="$FAKE_ROOT/bin"; FAKE_DATA="$FAKE_ROOT/data"
mkdir -p "$FAKE_BIN" "$FAKE_DATA"
trap 'rm -rf "$FAKE_ROOT"' EXIT
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -e
D="${FAKE_DATA_DIR:-/tmp}"; args="$*"
# Recorded so a test can assert a cached re-run makes no NEW upstream calls.
# Counting calls is the real property; hiding gh from PATH only proves the
# preflight check fires.
[ -n "${GH_CALL_LOG:-}" ] && printf '%s\n' "$args" >> "$GH_CALL_LOG"
if [[ "$args" == *"/pulls/"*"/files"* ]]; then
  n=$(echo "$args" | grep -oE 'pulls/[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [[ -n "$n" && -f "$D/throttle_${n}" ]]; then
    echo "gh: API rate limit exceeded for user ID 1 (HTTP 403)" >&2
    exit 1
  fi
  [[ -n "$n" && -f "$D/files_${n}.json" ]] && cat "$D/files_${n}.json" || echo "[]"
  exit 0
fi
if [[ "$args" == *"/commits"* ]]; then
  n=$(echo "$args" | grep -oE 'pulls/[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  FAKE_PR="$n" python3 - "$D/gql.json" <<'PY'
import json,os,sys
data=json.load(open(sys.argv[1])); want=int(os.environ["FAKE_PR"]); out=[]
for node in data["data"]["repository"]["pullRequests"]["nodes"]:
    if int(node["number"])!=want: continue
    for wrap in node["commits"]["nodes"]:
        c=wrap["commit"]; a=c["authors"]["nodes"][0]
        out.append({"sha":c["oid"],"author":{"login":(a.get("user") or {}).get("login") or ""},
                    "commit":{"message":c["messageHeadline"],"author":{"name":a.get("name") or ""}}})
print(json.dumps(out))
PY
  exit 0
fi
if [[ "$args" == *"/pulls"* ]]; then
  python3 - "$D/gql.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1])); out=[]
for n in data["data"]["repository"]["pullRequests"]["nodes"]:
    out.append({"number":n["number"],"title":n["title"],"body":n.get("body") or "",
                "merged_at":n["mergedAt"],"html_url":n["url"],
                "user":{"login":(n.get("author") or {}).get("login") or ""},
                "files":n.get("files") or {"nodes":[]}})
print(json.dumps(out))
PY
  exit 0
fi
echo "unknown gh call: $args" >&2; exit 1
GH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH" FAKE_DATA_DIR="$FAKE_DATA"
files() { printf '%s' "$2" > "$FAKE_DATA/files_$1.json"; }
run() { MINE_CACHE_DIR="$(mktemp -d)" "$SCRIPT" "$@"; }

# Compact PR node builder used by every fixture.
pygql() { printf '%s' "$1" | python3 -c 'import json,sys; json.dump({"data":{"repository":{"pullRequests":{"nodes":json.load(sys.stdin)}}}}, sys.stdout)' > "$FAKE_DATA/gql.json"; }

out=$(run --help); rc=$?
if (( rc == 0 )) && echo "$out" | grep -q "Usage: mine-confirmed-defects"; then ok "help prints usage and exits 0"
else fail_msg "help prints usage — rc=$rc out=$out"; fi

pygql '[{"number":1,"title":"Add auth token default","body":"","mergedAt":"2026-01-10T10:00:00Z","url":"https://github.com/owner/app/pull/1","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"aaa111","messageHeadline":"Add auth token default","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":2,"title":"Revert \"Add auth token default\"","body":"","mergedAt":"2026-01-11T10:00:00Z","url":"https://github.com/owner/app/pull/2","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"bbb222","messageHeadline":"Revert \"Add auth token default\"","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 1 '[{"filename":"action.yml","patch":"@@ -1,3 +1,4 @@\n inputs:\n+    default: ${{ github.token }}\n     required: true\n"}]'
files 2 '[{"filename":"action.yml","patch":"@@ -1,4 +1,3 @@\n inputs:\n-    default: ${{ github.token }}\n     required: true\n"}]'
tmp=$(mktemp)
out=$(run owner/app --out "$tmp" 2>&1)
if echo "$out" | grep -q "cases: 1" && echo "$out" | grep -q "errors: 0"; then ok "human revert is mined"
else fail_msg "human revert is mined — $out"; fi
if python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["cases"][0]["defects"][0]; assert e["labelEvidence"]["kind"]=="revert" and e["lens"]=="security" and e["trigger"].startswith("given ")' "$tmp"
then ok "revert evidence kind and token→security lens"
else fail_msg "revert evidence kind and token→security lens"; fi

pygql '[{"number":1,"title":"Add widget","body":"","mergedAt":"2026-01-10T10:00:00Z","url":"https://github.com/owner/app/pull/1","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/a.ts"}]},"commits":{"nodes":[{"commit":{"oid":"aaa111","messageHeadline":"Add widget","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":2,"title":"Revert \"Add widget\"","body":"","mergedAt":"2026-01-11T10:00:00Z","url":"https://github.com/owner/app/pull/2","author":{"login":"vibecodereview[bot]"},"files":{"nodes":[{"path":"src/a.ts"}]},"commits":{"nodes":[{"commit":{"oid":"bbb222","messageHeadline":"Revert \"Add widget\"","authors":{"nodes":[{"name":"vcr","user":{"login":"vibecodereview[bot]"}}]}}}]}}]'
files 1 '[{"filename":"src/a.ts","patch":"@@ -0,0 +1,2 @@\n+export const widget = 1\n"}]'
files 2 '[{"filename":"src/a.ts","patch":"@@ -1,2 +0,0 @@\n-export const widget = 1\n"}]'
out=$(run owner/app --out "$tmp" 2>&1)
if echo "$out" | grep -q "cases: 0"; then ok "bot revert is not evidence"
else fail_msg "bot revert is not evidence — $out"; fi

pygql '[{"number":5,"title":"Add parser","body":"","mergedAt":"2026-01-12T10:00:00Z","url":"https://github.com/owner/app/pull/5","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/parse.ts"}]},"commits":{"nodes":[{"commit":{"oid":"c1","messageHeadline":"Add parser","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}},{"commit":{"oid":"c2","messageHeadline":"fix: reject an empty chair reply","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}},{"commit":{"oid":"c3","messageHeadline":"fix: drop find from allowlist","authors":{"nodes":[{"name":"vcr","user":{"login":"vibecodereview[bot]"}}]}}},{"commit":{"oid":"c4","messageHeadline":"fix: address review comments","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 5 '[{"filename":"src/parse.ts","patch":"@@ -1,1 +1,3 @@\n export function parse(s) {\n+  if (!s) throw new Error(\"empty\")\n   return s\n }"}]'
out=$(run owner/app --out "$tmp" 2>&1)
if python3 -c 'import json,sys; ev=json.load(open(sys.argv[1]))["cases"][0]["defects"]; assert len(ev)==1 and ev[0]["labelEvidence"]["kind"]=="in-pr-correction" and ev[0]["labelEvidence"]["url"].endswith("/commit/c2")' "$tmp"
then ok "human in-pr fix kept; bot and address-review dropped"
else fail_msg "human in-pr fix kept — $out"; fi

pygql '[{"number":10,"title":"Wire the default token","body":"","mergedAt":"2026-01-13T10:00:00Z","url":"https://github.com/owner/app/pull/10","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"d1","messageHeadline":"Wire the default token","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":11,"title":"Fix composite action token default","body":"Fixes #10","mergedAt":"2026-01-14T10:00:00Z","url":"https://github.com/owner/app/pull/11","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"d2","messageHeadline":"Fix composite action token default","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 10 '[{"filename":"action.yml","patch":"@@ -1,2 +1,3 @@\n inputs:\n+    default: ${{ github.token }}\n     required: true\n"}]'
files 11 '[{"filename":"action.yml","patch":"@@ -1,3 +1,2 @@\n inputs:\n-    default: ${{ github.token }}\n     required: true\n"}]'
out=$(run owner/app --out "$tmp" 2>&1)
if python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["cases"][0]; assert c["pr"]==10 and c["defects"][0]["labelEvidence"]["kind"]=="later-fix-commit" and c["defects"][0]["labelEvidence"]["url"].endswith("/pull/11")' "$tmp"
then ok "later-fix that undoes an added line is mined"
else fail_msg "later-fix that undoes an added line — $out"; fi

pygql '[{"number":20,"title":"Add header","body":"","mergedAt":"2026-01-15T10:00:00Z","url":"https://github.com/owner/app/pull/20","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/a.ts"}]},"commits":{"nodes":[{"commit":{"oid":"e1","messageHeadline":"Add header","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":21,"title":"Fix footer copy","body":"","mergedAt":"2026-01-16T10:00:00Z","url":"https://github.com/owner/app/pull/21","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/a.ts"}]},"commits":{"nodes":[{"commit":{"oid":"e2","messageHeadline":"Fix footer copy","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 20 '[{"filename":"src/a.ts","patch":"@@ -1,1 +1,2 @@\n+export const header = 1\n export const mid = 1\n"}]'
files 21 '[{"filename":"src/a.ts","patch":"@@ -40,1 +40,2 @@\n export const footer = 1\n+export const extra = 2\n"}]'
out=$(run owner/app --out "$tmp" 2>&1)
if echo "$out" | grep -q "cases: 0"; then ok "later change on another hunk is not a label"
else fail_msg "later change on another hunk is not a label — $out"; fi

# Determinism uses the revert fixture still on disk from the first case? rewrite it.
pygql '[{"number":1,"title":"Add auth token default","body":"","mergedAt":"2026-01-10T10:00:00Z","url":"https://github.com/owner/app/pull/1","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"aaa111","messageHeadline":"Add auth token default","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":2,"title":"Revert \"Add auth token default\"","body":"","mergedAt":"2026-01-11T10:00:00Z","url":"https://github.com/owner/app/pull/2","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"action.yml"}]},"commits":{"nodes":[{"commit":{"oid":"bbb222","messageHeadline":"Revert \"Add auth token default\"","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 1 '[{"filename":"action.yml","patch":"@@ -1,3 +1,4 @@\n inputs:\n+    default: ${{ github.token }}\n     required: true\n"}]'
files 2 '[{"filename":"action.yml","patch":"@@ -1,4 +1,3 @@\n inputs:\n-    default: ${{ github.token }}\n     required: true\n"}]'
a=$(mktemp); b=$(mktemp)
run owner/app --out "$a" >/dev/null
run owner/app --out "$b" >/dev/null
if diff -q "$a" "$b" >/dev/null; then ok "re-run writes an identical file"
else fail_msg "re-run writes an identical file"; fi

echo '{"cases":[{"id":"x","repository":"o/r","pr":1,"mergedAt":"t","diff":"","defects":[]}]}' > "$tmp"
vout=$(run --validate "$tmp" 2>&1); vrc=$?
if (( vrc != 0 )) && echo "$vout" | grep -q "errors:"; then ok "validator rejects an incomplete case"
else fail_msg "validator rejects an incomplete case — rc=$vrc $vout"; fi

# A full fleet mine costs about two API calls per merged pull request, more than
# an hour's rate limit allows, so the cache is what makes a throttled run
# resumable instead of total loss.
CACHE="$(mktemp -d)"
GH_CALL_LOG="$FAKE_DATA/n1.txt" MINE_CACHE_DIR="$CACHE" "$SCRIPT" owner/app --out "$FAKE_DATA/c1.json" >/dev/null 2>&1
GH_CALL_LOG="$FAKE_DATA/n2.txt" MINE_CACHE_DIR="$CACHE" "$SCRIPT" owner/app --out "$FAKE_DATA/c2.json" >/dev/null 2>&1
n1=$(wc -l < "$FAKE_DATA/n1.txt" 2>/dev/null | tr -d ' ')
n2=$(wc -l < "$FAKE_DATA/n2.txt" 2>/dev/null | tr -d ' ')
if (( n1 > 0 )) && (( ${n2:-0} == 0 )) && diff -q "$FAKE_DATA/c1.json" "$FAKE_DATA/c2.json" >/dev/null; then
  ok "a cached re-run makes no new upstream calls"
else
  fail_msg "a cached re-run makes no new upstream calls ($n1 then ${n2:-0})"
fi

# A cache that can poison a run is worse than no cache: bad data outlives the
# run that wrote it.
for f in "$CACHE"/*.json; do [ -e "$f" ] || continue; printf 'not json' > "$f"; done
GH_CALL_LOG="$FAKE_DATA/n3.txt" MINE_CACHE_DIR="$CACHE" "$SCRIPT" owner/app --out "$FAKE_DATA/c3.json" >/dev/null 2>&1
n3=$(wc -l < "$FAKE_DATA/n3.txt" 2>/dev/null | tr -d ' ')
if (( ${n3:-0} > 0 )) && diff -q "$FAKE_DATA/c1.json" "$FAKE_DATA/c3.json" >/dev/null; then
  ok "a corrupt cache entry is discarded and refetched"
else
  fail_msg "a corrupt cache entry is discarded and refetched (refetched ${n3:-0})"
fi

# Two different queries must never share an entry, or one repo's pull requests
# would be served for another's.
CK="$(mktemp -d)"
MINE_CACHE_DIR="$CK" "$SCRIPT" owner/app --out "$FAKE_DATA/k1.json" >/dev/null 2>&1
kb=$(ls -1 "$CK" 2>/dev/null | wc -l | tr -d ' ')
MINE_CACHE_DIR="$CK" "$SCRIPT" owner/other --out "$FAKE_DATA/k2.json" >/dev/null 2>&1
ka=$(ls -1 "$CK" 2>/dev/null | wc -l | tr -d ' ')
if (( kb > 0 )) && (( ka > kb )); then
  ok "a different query gets its own cache entry"
else
  fail_msg "a different query gets its own cache entry ($kb -> $ka)"
fi

# The real run that motivated this PR was throttled while fetching a PR's
# files, not while listing PRs: every repo's PR list had already been
# fetched. That path must also pause and emit what was gathered, not crash
# with an unhandled exception and no output file.
pygql '[{"number":30,"title":"Add greeting","body":"","mergedAt":"2026-01-20T10:00:00Z","url":"https://github.com/owner/app/pull/30","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/g.ts"}]},"commits":{"nodes":[{"commit":{"oid":"f1","messageHeadline":"Add greeting","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}},{"number":31,"title":"Fix greeting bug","body":"Fixes #30","mergedAt":"2026-01-21T10:00:00Z","url":"https://github.com/owner/app/pull/31","author":{"login":"pooriaarab"},"files":{"nodes":[{"path":"src/g.ts"}]},"commits":{"nodes":[{"commit":{"oid":"f2","messageHeadline":"Fix greeting bug","authors":{"nodes":[{"name":"Pooria","user":{"login":"pooriaarab"}}]}}}]}}]'
files 30 '[{"filename":"src/g.ts","patch":"@@ -1,1 +1,2 @@\n export const x = 1\n+export const greeting = 1\n"}]'
files 31 '[{"filename":"src/g.ts","patch":"@@ -1,2 +1,1 @@\n export const x = 1\n-export const greeting = 1\n"}]'
touch "$FAKE_DATA/throttle_30"
rlout=$(run owner/app --out "$FAKE_DATA/rl.json" 2>&1); rlrc=$?
rm -f "$FAKE_DATA/throttle_30"
if (( rlrc == 0 )) && [ -f "$FAKE_DATA/rl.json" ] && echo "$rlout" | grep -q "rate limited on"; then
  ok "a throttle while fetching patches still writes partial output"
else
  fail_msg "a throttle while fetching patches still writes partial output — rc=$rlrc $rlout"
fi

# A throttle pauses the run; every other failure must still fail loudly, or a
# 404 or auth error would silently produce a short dataset.
CE="$(mktemp -d)"
cat > "$FAKE_BIN/gh" <<'BROKEN'
#!/usr/bin/env bash
echo "gh: Not Found (HTTP 404)" >&2
exit 1
BROKEN
chmod +x "$FAKE_BIN/gh"
if MINE_CACHE_DIR="$CE" "$SCRIPT" owner/app --out "$FAKE_DATA/e1.json" >/dev/null 2>&1; then
  fail_msg "a non-throttle API failure still exits non-zero"
else
  ok "a non-throttle API failure still exits non-zero"
fi

echo "---"; echo "$pass passed, $fail failed"
(( fail == 0 ))
