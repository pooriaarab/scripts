#!/usr/bin/env bash
# Generate ONE webhook-auth secret and set it on every Cloudflare Worker that
# serves the webhook, then print the value so you can paste it into the
# provider's dashboard field. Both sides MUST hold the same value — if the
# provider field is empty or differs, the route 401s every real inbound while
# synthetic tests still pass. See the messaging-bot-onboarding-setup skill.
#
# Usage:
#   set-messaging-webhook-key.sh <ENV_VAR> <worker-1> [worker-2 ...]
#
# Examples:
#   set-messaging-webhook-key.sh SENDBLUE_WEBHOOK_SECRET content-rabbit-staging content-rabbit-production
#   set-messaging-webhook-key.sh WHATSAPP_VERIFY_TOKEN   content-rabbit-staging content-rabbit-production
#
# Notes:
# - Prefix defaults by var name (sbwh_ / crwa_ / generic wh_); override with SECRET_PREFIX.
# - Run from the worker dir (where `wrangler secret put --name` resolves), or set WRANGLER_DIR.
# - This does NOT edit your .env.local — update the app's local env separately so
#   local dev matches. It also does NOT touch the provider dashboard — that field
#   is a human/browser step (paste the printed value and SAVE).
set -euo pipefail

VAR="${1:-}"
shift || true
WORKERS=("$@")

if [[ -z "$VAR" || ${#WORKERS[@]} -eq 0 ]]; then
  echo "usage: $0 <ENV_VAR> <worker-1> [worker-2 ...]" >&2
  exit 2
fi

case "$VAR" in
  SENDBLUE_*) DEFAULT_PREFIX="sbwh_" ;;
  WHATSAPP_*) DEFAULT_PREFIX="crwa_" ;;
  *)          DEFAULT_PREFIX="wh_" ;;
esac
PREFIX="${SECRET_PREFIX:-$DEFAULT_PREFIX}"

SECRET="${PREFIX}$(openssl rand -hex 24)"

[[ -n "${WRANGLER_DIR:-}" ]] && cd "$WRANGLER_DIR"

echo "=== $VAR ==="
echo "$SECRET"
echo "  ^ paste this into the provider's secret field (Sendblue Global Secret /"
echo "    WhatsApp webhook Verify token / etc.) and SAVE."
echo

for w in "${WORKERS[@]}"; do
  if out=$(printf '%s' "$SECRET" | npx wrangler secret put "$VAR" --name "$w" 2>&1); then
    echo "  [$w] $(printf '%s\n' "$out" | grep -iE "success|uploaded" | head -1)"
  else
    echo "  [$w] FAILED — full wrangler output:" >&2
    printf '%s\n' "$out" | sed "s/^/    /" >&2
    exit 1
  fi
done

echo
echo "Done. Both sides must match. Verify with a synthetic signed POST + a DB row"
echo "check (not just a 200) — see the messaging-bot-onboarding-setup skill."
