#!/usr/bin/env bash
# API contract and authorization gate, driven by an OpenAPI spec.
#
# Wraps `scout` (https://github.com/tester-army/scout, MIT, no account) and
# works around two upstream quirks that otherwise make the gate unusable. See
# api-contract-gate.md for the pattern and where the gate belongs.
#
#   scout-gate.sh <base-url>
#
# Reads scout.json from the current directory, so run it from the repo root.
# Scout does not search parent directories.
#
# Optional environment:
#   SCOUT_MIN_COVERAGE       coverage floor, default 90
#   SCOUT_SEVERITY           gate severity, default high
#   SCOUT_MAX_REQUESTS       sweep cap, default 300
#   SCOUT_VERSION            pinned scout version, default 0.3.0
#   SCOUT_REPORT             report path, default scout-report.json
#   CF_ACCESS_CLIENT_ID      Cloudflare Access service token, when the target
#   CF_ACCESS_CLIENT_SECRET  sits behind Access. Set both, or neither.
#   API_TOKEN                sent as `Authorization: Bearer` when set.
#
# Scout expands a `$VAR` inside a --header itself, at request time, and redacts
# it from output. So the secret never reaches the process table or a log line.
set -euo pipefail

BASE_URL="${1:?usage: scout-gate.sh <base-url>}"
MIN_COVERAGE="${SCOUT_MIN_COVERAGE:-90}"
SEVERITY="${SCOUT_SEVERITY:-high}"
MAX_REQUESTS="${SCOUT_MAX_REQUESTS:-300}"
REPORT="${SCOUT_REPORT:-scout-report.json}"

# Pinned. Scout is pre-1.0 and its config-writing behaviour changes between
# minors. Bump deliberately, after re-reading `scout init`.
SCOUT_VERSION="${SCOUT_VERSION:-0.3.0}"
scout() { npx --yes "@testerarmy/scout@${SCOUT_VERSION}" "$@"; }

if [ ! -f scout.json ]; then
  echo "No scout.json in $(pwd)." >&2
  echo "Scout reads it from the working directory and does not search upward." >&2
  exit 2
fi

# Scout needs Node 22.12+. Fail with the reason, not a stack trace.
# shellcheck disable=SC2016  # this is JavaScript, not shell; nothing to expand
node -e 'const [a,b] = process.versions.node.split(".").map(Number);
  if (a < 22 || (a === 22 && b < 12)) {
    console.error(`scout needs Node >=22.12, got ${process.versions.node}`);
    process.exit(1);
  }'

# TRAP 1. `scout init` rewrites scout.json from its flags. It keeps
# allowedMethods, allowedPaths, authProfiles and headers, but drops
# policy.rateLimit and policy.budget -- buildConfig has no spread for them. So a
# deliberately low rate limit is silently reset to the default 5. It also
# overwrites baseUrl with whatever we just tested, which would leave a localhost
# URL staged after a local run. Snapshot and restore.
cp scout.json scout.json.gate-bak
trap 'mv -f scout.json.gate-bak scout.json 2>/dev/null || true' EXIT

headers=()
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  # shellcheck disable=SC2016  # scout expands $VAR at request time, on purpose
  headers+=(--header 'CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID')
  # shellcheck disable=SC2016
  headers+=(--header 'CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET')
elif [ -n "${CF_ACCESS_CLIENT_ID:-}${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  echo "Only one half of the Cloudflare Access service token is set." >&2
  echo "Set both CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET, or neither." >&2
  exit 2
fi

if [ -n "${API_TOKEN:-}" ]; then
  # shellcheck disable=SC2016
  headers+=(--header 'Authorization: Bearer $API_TOKEN')
fi

echo "Scout gate against ${BASE_URL}"
scout init --base-url "$BASE_URL"

# An empty array expands as unbound under `set -u` in bash 3.2, which macOS
# still ships. The `${a[@]+"${a[@]}"}` form is the portable guard.
scout sweep --max-requests "$MAX_REQUESTS" ${headers[@]+"${headers[@]}"}

# TRAP 2. `report --ci` defaults --min-coverage to 100, which no sweep can
# satisfy. Always pass it explicitly or the gate can never go green.
#
# The JSON report exits nonzero on a gate failure. Do not let `set -e` kill the
# script here. The human-readable report below is what makes that failure
# legible in the CI log, and it must still run. The final command's exit code is
# what gates.
scout report --ci \
  --min-coverage "$MIN_COVERAGE" \
  --severity-threshold "$SEVERITY" \
  --json > "$REPORT" || true

scout report --ci --min-coverage "$MIN_COVERAGE" --severity-threshold "$SEVERITY"
