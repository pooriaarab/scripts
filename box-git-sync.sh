#!/usr/bin/env bash
# Runs inside a Box that already holds the repo (an environment cloned it).
# Brings the checkout to the commit the laptop is on, without uploading a tree.
#   $1 = repo dir   $2 = target commit sha   $3 = lockfile hash
set -uo pipefail
dest="$1"; sha="$2"; lock="${3:-}"
case "$dest" in /home/user/*) : ;; *) echo "ERR: refusing $dest" >&2; exit 2 ;; esac
case "$dest" in *..*) echo "ERR: .. in path" >&2; exit 2 ;; esac
cd "$dest" || { echo "ERR: no $dest" >&2; exit 2; }

# An environment clone is shallow, so the commit may not be present yet.
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  git fetch --depth 1 origin "$sha" >/dev/null 2>&1 \
    || git fetch --unshallow origin >/dev/null 2>&1 \
    || git fetch origin >/dev/null 2>&1
fi
git cat-file -e "$sha^{commit}" 2>/dev/null || { echo "ERR: commit $sha not reachable" >&2; exit 3; }
git checkout -q --detach "$sha" 2>/dev/null || { echo "ERR: checkout failed" >&2; exit 4; }
echo "at $(git rev-parse --short HEAD)"

prev=$(cat .box-lock-hash 2>/dev/null || true)
if [ -n "$lock" ] && [ "$prev" != "$lock" ]; then
  # Only record the lockfile as installed when the install actually succeeded.
  if out=$(bun install --frozen-lockfile 2>&1) || out=$(bun install 2>&1); then
    printf '%s' "$lock" > .box-lock-hash
    echo "installed=yes"
  else
    echo "install FAILED" >&2; printf '%s\n' "$out" | tail -20 >&2; exit 1
  fi
else
  echo "installed=no"
fi
