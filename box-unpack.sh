#!/usr/bin/env bash
# Runs inside an ascii.dev Box. Unpacks the delta box-fast-attach sends.
#   $1 = base64 of a gzipped tar   $2 = destination dir
#   $3 = lockfile hash              $4 = base64 of the newline-separated
#                                        paths to delete
#
# The payload arrives as its OWN argv word, never interpolated into a -c
# string: `bash -lc "...$VAR"` mangles a large blob into a single byte and
# still exits 0.
set -euo pipefail

b64="$1"; dest="$2"; lock="${3:-}"; deletions_b64="${4:-}"

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
#
# Do NOT pipe `tar -tzf` straight into `grep -q`. Under `set -o pipefail`,
# `grep -q` exits as soon as it matches, `tar` then dies of SIGPIPE (141), and
# pipefail reports 141 for the pipeline instead of grep's 0 -- so the `if` that
# is supposed to REJECT the archive evaluates false and extraction proceeds.
# The bigger the archive the more likely the race, which is backwards for a
# security check. Materialise the listing first, then grep the file.
tmp="$(mktemp)"; listing="$(mktemp)"
trap 'rm -f "$tmp" "$listing"' EXIT
printf '%s' "$b64" | base64 -d > "$tmp"
tar -tzf "$tmp" > "$listing"
if grep -qE '(^|/)\.\.(/|$)|^/' "$listing"; then
  echo "ERR: archive contains a path escaping the destination" >&2; exit 2
fi
tar -xzf "$tmp" --warning=no-unknown-keyword -C "$dest"

# Delete files the caller says are gone. Same escape checks apply.
#
# Two things this argument has already got wrong:
#  - it was an environment variable first. `box exec` runs the command on the
#    Box, so a variable exported around the local `box` process never arrives,
#    and every deletion was skipped while the call still reported success.
#  - then it was a raw newline-separated argument. `box exec` joins argv into a
#    shell command string, so an embedded newline ended the line and ran the
#    next path as a command ("bash: docs/space: No such file or directory").
# Base64 keeps it to a single word with no shell-significant characters.
if [ -n "$deletions_b64" ]; then
  printf '%s' "$deletions_b64" | base64 -d | while IFS= read -r rel; do
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
