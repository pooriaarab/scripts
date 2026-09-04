#!/usr/bin/env bash
# Give every runner service on this host a shared, content-addressed cache.
#
# Caches must live OUTSIDE the job workspace: actions/checkout cleans the
# workspace on every run, so a cache inside it is deleted before it can help.
# This script creates a cache root and points each runner service at it with a
# systemd drop-in.
#
# Each service keeps its own HOME. bun and npm caches are content-addressed
# and safe to share across every repo. turbo and playwright are namespaced per
# repo instead: turbo to avoid cross-repo cache-key collisions, and playwright
# so a job in one repo can't leave a trojaned browser binary for another
# repo's jobs to execute. A shared HOME would not be safe at all: parallel
# installs race on the package manager's home directory and fail with "Text
# file busy".
#
# This script never restarts a service. Restarting a busy runner kills the job
# it is running. Each service picks the new environment up on its next restart.
#
# Usage (as root on the runner host):
#   ./ci-cache-dropin.sh [--dry-run]
# Environment:
#   CI_CACHE_ROOT  cache root (default /opt/ci-cache)
#   RUNNER_USER    account the runner services run as (default actions)
set -euo pipefail

CI_CACHE_ROOT="${CI_CACHE_ROOT:-/opt/ci-cache}"
RUNNER_USER="${RUNNER_USER:-actions}"
DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

run() {
  if $DRY_RUN; then
    printf 'would run: %s\n' "$*"
  else
    "$@"
  fi
}

if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
  echo "Run this as root: it writes under /etc/systemd/system." >&2
  exit 1
fi

RUNNER_GROUP="$(id -gn "$RUNNER_USER")" || {
  echo "error: RUNNER_USER '$RUNNER_USER' has no such account (or no primary group)" >&2
  exit 1
}

run mkdir -p "$CI_CACHE_ROOT"
run chown "$RUNNER_USER:$RUNNER_GROUP" "$CI_CACHE_ROOT"
run chmod 2775 "$CI_CACHE_ROOT"
for dir in bun npm turbo playwright; do
  run mkdir -p "$CI_CACHE_ROOT/$dir"
  run chown "$RUNNER_USER:$RUNNER_GROUP" "$CI_CACHE_ROOT/$dir"
  run chmod 2775 "$CI_CACHE_ROOT/$dir"
done

written=0
for unit in /etc/systemd/system/actions.runner.*.service; do
  [[ -e "$unit" ]] || continue
  name="$(basename "$unit" .service)"
  # The owner-repo segment of the unit name is ambiguous when either contains a
  # hyphen (actions.runner.my-org-app... could be owner "my-org" or "my"). The
  # runner's WorkingDirectory is not ambiguous, but add-repo.sh names it after
  # the repo alone ($install_root/<repo>, or <repo>-<instance>), dropping the
  # owner. Two different owners' repos that share a name (or two install
  # roots) would collide on basename(workdir) and defeat the per-repo
  # isolation below, so namespace on the full path instead: it is unique by
  # construction.
  workdir="$(sed -n 's/^WorkingDirectory=//p' "$unit" | head -1)"
  if [[ -z "$workdir" ]]; then
    echo "skip $name: unit has no WorkingDirectory" >&2
    continue
  fi
  repo="$(sed 's#^/##; s#/#-#g' <<<"$workdir")"
  dropin_dir="$unit.d"
  run mkdir -p "$dropin_dir"
  run mkdir -p "$CI_CACHE_ROOT/turbo/$repo" "$CI_CACHE_ROOT/playwright/$repo"
  run chown "$RUNNER_USER:$RUNNER_GROUP" "$CI_CACHE_ROOT/turbo/$repo" "$CI_CACHE_ROOT/playwright/$repo"
  if $DRY_RUN; then
    printf 'would write: %s/20-ci-cache.conf (TURBO_CACHE_DIR=%s/turbo/%s, PLAYWRIGHT_BROWSERS_PATH=%s/playwright/%s)\n' \
      "$dropin_dir" "$CI_CACHE_ROOT" "$repo" "$CI_CACHE_ROOT" "$repo"
  else
    cat > "$dropin_dir/20-ci-cache.conf" <<EOF
[Service]
Environment="BUN_INSTALL_CACHE_DIR=$CI_CACHE_ROOT/bun"
Environment="npm_config_cache=$CI_CACHE_ROOT/npm"
Environment="TURBO_CACHE_DIR=$CI_CACHE_ROOT/turbo/$repo"
Environment="PLAYWRIGHT_BROWSERS_PATH=$CI_CACHE_ROOT/playwright/$repo"
EOF
  fi
  written=$((written + 1))
done

run systemctl daemon-reload

echo "Drop-ins written: $written"
echo "Each service reads the new environment on its next restart. Restart a"
echo "service only while it is idle, or you cancel the job it is running."
