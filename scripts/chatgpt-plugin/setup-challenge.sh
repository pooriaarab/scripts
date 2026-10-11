#!/bin/sh
# Deploy the openai-apps-challenge worker and add a redirect rule on a zone.
#
#   CLOUDFLARE_API_TOKEN=... sh setup-challenge.sh <zone_id> <domain> <token>
#
# First call uploads the worker (account-level, idempotent). Each subsequent
# call adds one domain's token to OPENAI_TOKENS and creates the zone redirect
# rule for /.well-known/openai-apps-challenge.
#
# Env:
#   CLOUDFLARE_API_TOKEN  token with Workers Scripts:Edit and Zone Rules:Edit
#   CF_ACCOUNT_ID         optional; discovered from /accounts when unset
#   WORKER_NAME           default: openai-apps-challenge
#   TOKENS_FILE           state file holding the {domain: token} map (default:
#                         ./openai-apps-tokens.json, keep out of git)

set -eu

ZONE_ID=$1; DOMAIN=$2; TOKEN=$3
WORKER_NAME=${WORKER_NAME:-openai-apps-challenge}
TOKENS_FILE=${TOKENS_FILE:-./openai-apps-tokens.json}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
API="https://api.cloudflare.com/client/v4"
AUTH="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

ACCOUNT=${CF_ACCOUNT_ID:-$(curl -fsS -H "$AUTH" "$API/accounts" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"][0]["id"])')}

# 1. Merge the token into the local map.
python3 - "$TOKENS_FILE" "$DOMAIN" "$TOKEN" <<'PY'
import json, sys, os
f, d, t = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(f)) if os.path.exists(f) else {}
data[d] = t
json.dump(data, open(f, 'w'), indent=2)
PY

# 2. Upload the worker with the merged map as OPENAI_TOKENS.
BOUNDARY="--F$(date +%s)"
{
  echo "--$BOUNDARY"
  echo 'Content-Disposition: form-data; name="metadata"'
  echo 'Content-Type: application/json'
  echo
  python3 -c "import json;print(json.dumps({'main_module':'worker.js','bindings':[{'name':'OPENAI_TOKENS','type':'plain_text','text':open('$TOKENS_FILE').read()}]}))"
  echo "--$BOUNDARY"
  echo 'Content-Disposition: form-data; name="worker.js"; filename="worker.js"'
  echo 'Content-Type: application/javascript+module'
  echo
  cat "$HERE/challenge-worker.js"
  echo "--$BOUNDARY--"
} | curl -fsS -X PUT -H "$AUTH" -H "Content-Type: multipart/form-data; boundary=$BOUNDARY" --data-binary @- \
  "$API/accounts/$ACCOUNT/workers/scripts/$WORKER_NAME" > /dev/null

# 3. Enable the workers.dev subdomain once.
curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"enabled":true}' "$API/accounts/$ACCOUNT/workers/scripts/$WORKER_NAME/subdomain" > /dev/null 2>&1 || true

SUBDOMAIN=$(curl -fsS -H "$AUTH" "$API/accounts/$ACCOUNT/workers/subdomain" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["subdomain"])')

# 4. Create (or merge into) the zone's dynamic redirect ruleset.
RULE=$(python3 -c "import json;print(json.dumps({'expression':'(http.host eq \"$DOMAIN\" and http.request.uri.path eq \"/.well-known/openai-apps-challenge\")','action':'redirect','action_parameters':{'from_value':{'status_code':302,'target_url':{'value':'https://$WORKER_NAME.$SUBDOMAIN.workers.dev/?h=$DOMAIN'},'preserve_query_string':False}},'description':'openai apps challenge redirect','enabled':True}))")

ENTRY=$(curl -sS -H "$AUTH" "$API/zones/$ZONE_ID/rulesets/phases/http_request_dynamic_redirect/entrypoint" || true)
if echo "$ENTRY" | grep -q '"rules"'; then
  MERGED=$(python3 -c "
import json,sys
entry=json.loads(sys.argv[1]); rule=json.loads(sys.argv[2])
rules=[r for r in entry.get('result',{}).get('rules',[]) if r.get('description')!='openai apps challenge redirect']
print(json.dumps({'rules':[rule]+rules}))
" "$ENTRY" "$RULE")
  curl -fsS -X PUT -H "$AUTH" -H 'Content-Type: application/json' -d "$MERGED" \
    "$API/zones/$ZONE_ID/rulesets/phases/http_request_dynamic_redirect/entrypoint" > /dev/null
else
  curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"name\":\"dynamic redirect rules\",\"kind\":\"zone\",\"phase\":\"http_request_dynamic_redirect\",\"rules\":[$RULE]}" \
    "$API/zones/$ZONE_ID/rulesets" > /dev/null
fi

echo "curl -sL https://$DOMAIN/.well-known/openai-apps-challenge  # expect: $TOKEN"
