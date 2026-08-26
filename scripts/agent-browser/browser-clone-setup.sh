#!/usr/bin/env bash
#
# browser-clone-setup.sh — clone ONE real Google Chrome profile for automation.
#
# WHY THIS EXISTS (keychain + Chrome-136 rationale):
#   agent-browser bundles Chrome-for-Testing, which uses a SEPARATE macOS Keychain
#   entry ("Chrome for Testing Safe Storage"). Cookies copied from real Chrome are
#   encrypted with the "Chrome Safe Storage" key, so they do NOT decrypt inside
#   Chrome-for-Testing — cookie-copy there fails.
#
#   Working approach: launch the REAL Google Chrome binary on a COPY of one real
#   profile, with --remote-debugging-port and a distinct --user-data-dir. Real
#   Chrome shares the one "Chrome Safe Storage" keychain key for ANY user-data-dir,
#   so copied cookies decrypt and non-Google logins stay live.
#   (Google-owned sites e.g. Gmail may still require one sign-in: Google binds its
#   session cookies to the device via DBSC, which a copy cannot reproduce.)
#
#   Launching real Chrome yourself WITH the debug flag on a NON-default user-data-dir
#   does NOT trigger the Chrome-136 "Allow remote debugging" prompt (that prompt only
#   fires when attaching to an already-running user session). So this is prompt-free.
#
# SEPARATION: each target clones EXACTLY ONE source profile into <clone>/Default and
#   rewrites "Local State" so the clone knows only that one profile. Clones never
#   share a dir, a port, or a profile list. Give each clone its own name and port.
#
# SAFE: the real profile is a read-only rsync source; this script only writes under
#   ~/.agent-browser/real-profiles/. Idempotent — re-run to refresh logins.
#
# USAGE:
#   browser-clone-setup.sh <clone-name> --source-profile "<Chrome profile dir>" [--port N]
#
# EXAMPLE:
#   # List your Chrome profile dir names first:
#   ls "$HOME/Library/Application Support/Google/Chrome"
#   # Then clone one (dir names look like "Default", "Profile 1", "Profile 2"):
#   browser-clone-setup.sh work --source-profile "Profile 1" --port 9333
#
set -euo pipefail

CHROME_ROOT="$HOME/Library/Application Support/Google/Chrome"
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CLONE_ROOT="$HOME/.agent-browser/real-profiles"

TARGET="${1:-}"
shift || true

[ -n "$TARGET" ] || { echo "usage: browser-clone-setup.sh <clone-name> --source-profile \"<Chrome profile dir>\" [--port N]" >&2; exit 2; }

SOURCE_PROFILE=""
PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source-profile) SOURCE_PROFILE="${2:-}"; shift 2 ;;
    --port)           PORT="${2:-}"; shift 2 ;;
    *) echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$SOURCE_PROFILE" ] || { echo "error: --source-profile is required (e.g. \"Profile 1\")" >&2; echo "  list: ls \"$CHROME_ROOT\"" >&2; exit 2; }

# Default port: deterministic per clone-name so two clones never collide.
# ponytail: cksum-mod is a naive hash; pass --port explicitly if you hit a clash.
if [ -z "$PORT" ]; then
  PORT=$(( 9300 + $(printf '%s' "$TARGET" | cksum | cut -d' ' -f1) % 100 ))
fi

CLONE_DIR="$CLONE_ROOT/$TARGET"
SRC_PROFILE_DIR="$CHROME_ROOT/$SOURCE_PROFILE"
SRC_LOCAL_STATE="$CHROME_ROOT/Local State"

[ -d "$SRC_PROFILE_DIR" ]  || { echo "error: source profile not found: $SRC_PROFILE_DIR" >&2; echo "  list: ls \"$CHROME_ROOT\"" >&2; exit 1; }
[ -f "$SRC_LOCAL_STATE" ]  || { echo "error: 'Local State' not found (needed for cookie key): $SRC_LOCAL_STATE" >&2; exit 1; }

# Refuse to clobber a clone whose Chrome is currently running on its port.
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "error: a Chrome is running on port $PORT (this clone is in use)." >&2
  echo "  Quit it first:  pkill -f -- \"--remote-debugging-port=$PORT\"" >&2
  exit 1
fi

# Fresh clone: wipe any prior (possibly cross-contaminated) copy so exactly one
# profile lands. Normalize the profile dir name to "Default" for a clean launch.
rm -rf "$CLONE_DIR"
DEST_PROFILE_DIR="$CLONE_DIR/Default"
mkdir -p "$DEST_PROFILE_DIR"

# "Local State" holds the encrypted cookie key (os_crypt). Copy it but REWRITE the
# profile list so the clone knows only "Default" — this is what keeps clones from
# ever seeing each other's profiles. Fall back to a raw copy if jq is absent.
if command -v jq >/dev/null 2>&1; then
  jq --arg src "$SOURCE_PROFILE" '{
    os_crypt: .os_crypt,
    hardware_acceleration_mode: (.hardware_acceleration_mode // {}),
    profile: {
      info_cache: { "Default": ((.profile.info_cache[$src]) // {name:"Automation"}) },
      last_used: "Default",
      profiles_order: ["Default"],
      last_active_profiles: ["Default"]
    }
  }' "$SRC_LOCAL_STATE" > "$CLONE_DIR/Local State" \
    || rsync -a "$SRC_LOCAL_STATE" "$CLONE_DIR/Local State"
else
  rsync -a "$SRC_LOCAL_STATE" "$CLONE_DIR/Local State"
fi

# Session-relevant subset only (skip Cache/Code Cache/GPUCache/Service Worker/etc.).
SUBSET=( "Cookies" "Local Storage" "IndexedDB" "Login Data" "Network" "Preferences" "Web Data" )
RSYNC_FAILED=0
for item in "${SUBSET[@]}"; do
  if [ -e "$SRC_PROFILE_DIR/$item" ]; then
    rsync -a "$SRC_PROFILE_DIR/$item" "$DEST_PROFILE_DIR/" || { echo "warn: rsync failed for '$item' (Chrome may have it locked)" >&2; RSYNC_FAILED=1; }
  fi
done
[ "$RSYNC_FAILED" -eq 0 ] || { echo "error: copy incomplete; quit Chrome and re-run." >&2; exit 1; }

echo ""
echo "Clone ready: $CLONE_DIR  (single profile: $SOURCE_PROFILE -> Default, port $PORT)"
echo "Launch:  \"$CHROME_BIN\" --user-data-dir=\"$CLONE_DIR\" --remote-debugging-port=$PORT --no-first-run --no-default-browser-check"
echo "Connect: agent-browser connect $PORT"
