#!/usr/bin/env bash
# Runs inside an ascii.dev Box. Unpacks the delta box-fast-attach sends.
#   $1 = base64 of a gzipped tar   $2 = destination dir
#   $3 = lockfile hash              $4 = newline-separated paths to delete
#
# The payload arrives as its OWN argv word, never interpolated into a -c
# string: `bash -lc "...$VAR"` mangles a large blob into a single byte and
# still exits 0.
set -euo pipefail

b64="$1"; dest="$2"; lock="${3:-}"; deletions="${4:-}"

# A caller could pass anything here, so refuse a destination that escapes the
# work root. os.path.basename-style trimming is not enough: ".." survives it.
case "$dest" in
  /home/user/work/*) : ;;
  *) echo "ERR: destination outside /home/user/work" >&2; exit 2 ;;
esac
case "$dest" in
  *..*) echo "ERR: destination contains .." >&2; exit 2 ;;
esac
mkdir -p "$dest"

# Refuse a tar that would write outside dest. GNU tar strips a leading "/" but
# happily follows "../", so check the member list before extracting anything.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '%s' "$b64" | base64 -d > "$tmp"
if tar -tzf "$tmp" | grep -qE '(^|/)\.\.(/|$)|^/'; then
  echo "ERR: archive contains a path escaping the destination" >&2; exit 2
fi
tar -xzf "$tmp" --warning=no-unknown-keyword -C "$dest"

# Delete files the caller says are gone. Same escape checks apply.
# This arrives as an ARGUMENT, not an environment variable: `box exec` runs the
# command on the Box, so a variable exported around the local `box` process
# never reaches it. That silently skipped every deletion.
if [ -n "$deletions" ]; then
  printf '%s\n' "$deletions" | while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in /*|*..*) continue ;; esac
    rm -f "$dest/$rel"
  done
fi

prev=$(cat "$dest/.box-lock-hash" 2>/dev/null || true)
if [ -n "$lock" ] && [ "$prev" != "$lock" ]; then
  # Only record the lockfile as installed when the install actually succeeded.
  # Writing the marker on failure hides a broken node_modules until the
  # lockfile changes again, which can be never.
  if out=$( cd "$dest" && bun install --frozen-lockfile 2>&1 ) \
     || out=$( cd "$dest" && bun install 2>&1 ); then
    printf '%s' "$lock" > "$dest/.box-lock-hash"
    echo "OK installed=yes"
  else
    echo "ERR install failed:" >&2
    printf '%s\n' "$out" | tail -20 >&2
    exit 1
  fi
else
  echo "OK installed=no"
fi
