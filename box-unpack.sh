#!/usr/bin/env bash
# $1 = base64 of a gzipped tar, $2 = destination dir, $3 = lock hash
set -euo pipefail
dest="$2"; lock="${3:-}"
mkdir -p "$dest"
printf '%s' "$1" | base64 -d | tar -xzf - --warning=no-unknown-keyword -C "$dest"
prev=$(cat "$dest/.box-lock-hash" 2>/dev/null || true)
if [ -n "$lock" ] && [ "$prev" != "$lock" ]; then
  ( cd "$dest" && (bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1) )
  printf '%s' "$lock" > "$dest/.box-lock-hash"
  echo "OK installed=yes"
else
  echo "OK installed=no"
fi
