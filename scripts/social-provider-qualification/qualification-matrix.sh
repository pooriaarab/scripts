#!/usr/bin/env bash
# Print repeatable, read-only local evidence for one Content Rabbit provider.
# It never reads secret values, opens a browser, or calls a social provider.
set -euo pipefail

provider="${1:-}"

if [[ -z "$provider" ]]; then
  echo "usage: $0 <provider>" >&2
  echo "providers: bluesky devto discord dribbble facebook farcaster ghost googlebusiness hashnode imessage instagram kick lemmy linkedin listmonk mastodon medium mewe moltbook nostr pinterest reddit skool slack snapchat telegram threads tiktok tumblr twitch vk whatsapp whop wordpress x youtube" >&2
  exit 2
fi

if [[ -z "${CONTENT_RABBIT_REPO:-}" ]]; then
  echo "CONTENT_RABBIT_REPO is not set; export it to the Content Rabbit checkout path" >&2
  exit 2
fi
repo="$CONTENT_RABBIT_REPO"

case "$provider" in
  x) provider="twitter" ;;
  bluesky|devto|discord|dribbble|facebook|farcaster|ghost|googlebusiness|hashnode|imessage|instagram|kick|lemmy|linkedin|listmonk|mastodon|medium|mewe|moltbook|nostr|pinterest|reddit|skool|slack|snapchat|telegram|threads|tiktok|tumblr|twitch|twitter|vk|whatsapp|whop|wordpress|youtube) ;;
  *) echo "unsupported provider: $provider" >&2; exit 2 ;;
esac

test_file="src/app/api/v1/posts/[postId]/publish/handlers/__tests__/${provider}.test.ts"
if [[ "$provider" == "twitter" ]]; then
  extra_tests=("src/app/api/v1/posts/[postId]/publish/handlers/__tests__/twitter-request.test.ts" "src/app/api/v1/posts/[postId]/publish/handlers/__tests__/twitter-media-request.test.ts")
elif [[ "$provider" == "linkedin" ]]; then
  extra_tests=("src/app/api/v1/posts/[postId]/publish/handlers/__tests__/linkedin-request.test.ts")
else
  extra_tests=()
fi

echo "== ${provider} local qualification =="
echo "repository: ${repo}"
echo

echo "-- live-test safety contract --"
echo "Use neutral test copy. Do not include the product or customer name."
echo "Verify media on the public provider page, not only in the API response."
echo "Delete every live test post and reply immediately after verification."
echo "Stop if cleanup fails."
echo

echo "-- capability matrix contract --"
echo "Record each operation as VERIFIED, UNSUPPORTED_BY_PROVIDER, NOT_IMPLEMENTED, or BLOCKED."
echo "Posts: create, read status, update, delete, schedule, and each supported media shape."
echo "Comments: list, read thread, reply, like or react, hide or moderate, mark read, and delete."
echo "Messages: list, read, send, reply, attach media, delete, and use group conversations."
echo "Authentication: connect, refresh, reconnect, disconnect, and handle revoked scopes."
echo "Sync: paginate, deduplicate, retry, respect rate limits, and run on the production schedule."
echo

echo "-- production secret names --"
case "$provider" in
  twitter|facebook|instagram|threads|linkedin|tiktok|youtube|googlebusiness|pinterest|reddit|tumblr|vk|dribbble|snapchat|kick|twitch|whop|mastodon|discord|telegram|imessage)
    (cd "$repo" && bun run packages/cli/scripts/integrations/status.ts "$provider" --env production)
    ;;
  *)
    echo "NOT_IMPLEMENTED: production secret status is not implemented for ${provider}."
    ;;
esac
echo

test_args=("$test_file")
if [[ ${#extra_tests[@]} -gt 0 ]]; then
  test_args+=("${extra_tests[@]}")
fi

echo "-- focused handler tests --"
(cd "$repo/apps/website" && bunx vitest run "${test_args[@]}" --reporter=dot)
echo

case "$provider" in
  twitter|linkedin|facebook|instagram|threads|bluesky)
    echo "-- comment adapter evidence --"
    adapter_file="$repo/apps/website/src/server/services/social-comments/platforms/${provider}.ts"
    if [[ ! -f "$adapter_file" ]]; then
      echo "missing comment adapter: $adapter_file" >&2
      exit 1
    fi
    echo "$adapter_file"
    ;;
esac

if [[ "$provider" == "twitter" ]]; then
  echo
  echo "-- X-specific live gates --"
  echo "Test text, one image, multiple images, one video, and one reply."
  echo "Do not test mixed image and video posts."
  echo "Confirm Stream is ready and its download URL returns HTTP 200."
  echo "Confirm each image or video appears on the public X post."
  echo "Use one bounded comment sync, then disable recurring sync."
  echo "Stop on credit depletion. Do not retry paid recent-search calls."
  echo "Test new-account OAuth separately from an existing connection."
  echo "Record X DMs as NOT_IMPLEMENTED until the adapter ships."
fi

case "$provider" in
  facebook|instagram)
    echo "-- DM adapter tests --"
    (cd "$repo/apps/website" && bunx vitest run src/server/services/dm/platforms/__tests__/dm.test.ts --reporter=dot)
    ;;
esac

echo
echo "Local proof passed. Complete the live console and test-account gates before marking READY."
