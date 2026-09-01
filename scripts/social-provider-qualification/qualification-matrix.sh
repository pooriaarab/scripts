#!/usr/bin/env bash
# Print repeatable, read-only local evidence for one Content Rabbit provider.
# It never reads secret values, opens a browser, or calls a social provider.
set -euo pipefail

provider="${1:-}"
repo="${CONTENT_RABBIT_REPO:-/Users/parab/Documents/Personal/content-rabbit/code/Content Rabbit}"

if [[ -z "$provider" ]]; then
  echo "usage: $0 <provider>" >&2
  echo "providers: x linkedin facebook instagram threads tiktok youtube pinterest bluesky mastodon reddit" >&2
  exit 2
fi

case "$provider" in
  x) provider="twitter" ;;
  twitter|linkedin|facebook|instagram|threads|tiktok|youtube|pinterest|bluesky|mastodon|reddit) ;;
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

echo "-- production secret names --"
(cd "$repo" && bun run packages/cli/scripts/integrations/status.ts "$provider" --env production)
echo

echo "-- focused handler tests --"
(cd "$repo/apps/website" && bunx vitest run "$test_file" "${extra_tests[@]}" --reporter=dot)
echo

case "$provider" in
  twitter|linkedin|facebook|instagram|threads|bluesky)
    echo "-- comment adapter evidence --"
    find "$repo/apps/website/src/server/services/social-comments/platforms" -maxdepth 1 -name "${provider}.ts" -print
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
  echo "Record X DMs as unsupported by Content Rabbit."
fi

case "$provider" in
  facebook|instagram)
    echo "-- DM adapter tests --"
    (cd "$repo/apps/website" && bunx vitest run src/server/services/dm/platforms/__tests__/dm.test.ts --reporter=dot)
    ;;
esac

echo
echo "Local proof passed. Complete the live console and test-account gates before marking READY."
