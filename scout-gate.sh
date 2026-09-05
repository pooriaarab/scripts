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

if [ $# -lt 1 ]; then
  echo "usage: scout-gate.sh <base-url>" >&2
  exit 2
fi
BASE_URL="$1"
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

# Scout needs Node 22.12+. Fail with the reason, not a stack trace. Exit 2:
# an old runtime is a usage/environment error, not "a finding at or above
# severity threshold" (exit 1 in the documented contract).
# shellcheck disable=SC2016  # this is JavaScript, not shell; nothing to expand
node -e 'const [a,b] = process.versions.node.split(".").map(Number);
  if (a < 22 || (a === 22 && b < 12)) {
    console.error(`scout needs Node >=22.12, got ${process.versions.node}`);
    process.exit(2);
  }'

# TRAP 1. `scout init` rewrites scout.json from its flags. It keeps
# allowedMethods, allowedPaths, authProfiles and headers, but drops
# policy.rateLimit and policy.budget -- buildConfig has no spread for them. So a
# deliberately low rate limit is silently reset to the default 5. It also
# overwrites baseUrl with whatever we just tested, which would leave a localhost
# URL staged after a local run. Snapshot and restore.
#
# The backup name carries a mktemp suffix, not a fixed name: two runs in the
# same working directory would otherwise share `scout.json.gate-bak` and one
# could overwrite or delete the other's snapshot. Restoration failure is
# reported, not swallowed, so a broken restore is visible in the log instead
# of leaving scout.json silently rewritten.
BACKUP="$(mktemp ./scout.json.gate-bak.XXXXXX)"
cp scout.json "$BACKUP"
trap 'mv -f "$BACKUP" scout.json || echo "warning: failed to restore scout.json from $BACKUP" >&2' EXIT

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

# Credentials go out in a --header only when one of the above set one. Refuse
# to send them to a plaintext, non-local target -- scout attaches whatever
# header we hand it to whatever host is in BASE_URL, with no scheme check of
# its own.
if [ ${#headers[@]} -gt 0 ]; then
  case "$BASE_URL" in
    https://*|http://localhost*|http://127.0.0.1*|http://\[::1\]*) ;;
    *)
      echo "Refusing to send credentials to a non-HTTPS, non-local base URL: ${BASE_URL}" >&2
      echo "Use https://, or drop API_TOKEN/CF_ACCESS_CLIENT_* for a plain HTTP target." >&2
      exit 2
      ;;
  esac
fi

echo "Scout gate against ${BASE_URL}"

# TRAP 3. The headers go on `init`, not on `sweep`. `sweep` has no --header
# option -- only --auth-profile -- so passing one fails the whole run with
# "error: unknown option '--header'". The docs list --header under request
# options for call, sweep and fuzz, which is wrong for sweep. `init` persists
# them into the config every later command in the run reads.
#
# They must be base headers rather than an authProfile. Scout strips only the
# spec-declared credential header for the missing-auth probe and leaves every
# other header alone, so edge-auth headers survive that probe. That matters: if
# they were stripped, the probe would hit the edge's 403 and never reach the
# app, and a missing app-level auth check would pass the gate.
#
# An empty array expands as unbound under `set -u` in bash 3.2, which macOS
# still ships. The `${a[@]+"${a[@]}"}` form is the portable guard.
scout init --base-url "$BASE_URL" ${headers[@]+"${headers[@]}"}

# `scout init` just reset policy.rateLimit and policy.budget to its own
# defaults (see TRAP 1 above). The on-disk file gets put back at EXIT, but
# that is too late for this sweep -- reapply both preserved values before it
# runs, so a limit or budget set for a fragile API is actually honoured this
# run, not just next time someone reads scout.json. Also print the preserved
# budget so the shell side can cap --max-requests at it: passing --max-requests
# 300 while scout.json asked for a lower budget would overrun the very API
# this is meant to protect.
BACKED_UP_BUDGET=$(BACKUP_FILE="$BACKUP" node -e '
  const fs = require("fs");
  const backup = JSON.parse(fs.readFileSync(process.env.BACKUP_FILE, "utf8"));
  const policy = backup.policy || {};
  const cfg = JSON.parse(fs.readFileSync("scout.json", "utf8"));
  cfg.policy = cfg.policy || {};
  if (policy.rateLimit !== undefined) cfg.policy.rateLimit = policy.rateLimit;
  if (policy.budget !== undefined) cfg.policy.budget = policy.budget;
  fs.writeFileSync("scout.json", JSON.stringify(cfg, null, 2));
  process.stdout.write(policy.budget === undefined ? "" : String(policy.budget));
')
if [ -z "${SCOUT_MAX_REQUESTS:-}" ] && [ -n "$BACKED_UP_BUDGET" ]; then
  MAX_REQUESTS="$BACKED_UP_BUDGET"
fi

scout sweep --max-requests "$MAX_REQUESTS"

# TRAP 2. `report --ci` defaults --min-coverage to 100, which no sweep can
# satisfy. Always pass it explicitly or the gate can never go green.
#
# The JSON report exits nonzero on a gate failure. Do not let `set -e` kill the
# script here. The human-readable report below is what makes that failure
# legible in the CI log, and it must still run. The final command's exit code is
# what gates. Create the report's directory first: otherwise a bad SCOUT_REPORT
# path fails the redirection itself, and `|| true` would swallow that write
# failure the same way it swallows a gate failure, leaving the artifact
# missing with nothing said about it.
mkdir -p "$(dirname -- "$REPORT")"
scout report --ci \
  --min-coverage "$MIN_COVERAGE" \
  --severity-threshold "$SEVERITY" \
  --json > "$REPORT" || true

scout report --ci --min-coverage "$MIN_COVERAGE" --severity-threshold "$SEVERITY"
