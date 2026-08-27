#!/usr/bin/env bash
# Join a Linux or macOS machine to the tailnet and give it a role.
# Idempotent: re-running reconciles rather than duplicating.
# Installs nothing that can reach the controller.
set -euo pipefail

HOSTNAME_NEW=""
ROLE="worker"
TAG=""
TAILNET_CIDR="100.64.0.0/10"

usage() {
  cat <<'USAGE'
Usage: onboard.sh --hostname NAME [--role worker|controller|consumer] [--tag tag:worker]

  --hostname  OS hostname to set BEFORE joining. Tailscale derives the node name
              from it at join time, and renaming afterwards strands the old node.
  --role      worker (default) opens inbound SSH; controller and consumer do not.
  --tag       ACL tag applied at join, e.g. tag:worker. Requires tagOwners.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOSTNAME_NEW="${2:-}"; shift 2 ;;
    --role)     ROLE="${2:-}"; shift 2 ;;
    --tag)      TAG="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$HOSTNAME_NEW" ] || { echo "--hostname is required" >&2; usage; exit 2; }
case "$ROLE" in worker|controller|consumer) ;; *) echo "invalid --role: $ROLE" >&2; exit 2 ;; esac

OS="$(uname -s)"
say() { printf '\n== %s\n' "$*"; }

# --- hostname, before the join -----------------------------------------------
say "hostname"
CURRENT="$(hostname -s 2>/dev/null || hostname)"
if [ "$CURRENT" = "$HOSTNAME_NEW" ]; then
  echo "already $HOSTNAME_NEW"
else
  echo "$CURRENT -> $HOSTNAME_NEW"
  if [ "$OS" = "Darwin" ]; then
    sudo scutil --set HostName "$HOSTNAME_NEW"
    sudo scutil --set LocalHostName "$HOSTNAME_NEW"
    sudo scutil --set ComputerName "$HOSTNAME_NEW"
  else
    sudo hostnamectl set-hostname "$HOSTNAME_NEW"
  fi
fi

# --- tailscale ----------------------------------------------------------------
say "tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  if [ "$OS" = "Darwin" ]; then
    echo "Install Tailscale from the App Store or https://tailscale.com/download/mac, then re-run." >&2
    exit 1
  fi
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if tailscale status >/dev/null 2>&1; then
  echo "already joined"
else
  UP_ARGS=(--hostname "$HOSTNAME_NEW")
  [ -n "$TAG" ] && UP_ARGS+=(--advertise-tags "$TAG")
  # No --accept-routes and no --advertise-exit-node: a worker routing traffic for
  # other nodes is a separate decision, not part of onboarding.
  sudo tailscale up "${UP_ARGS[@]}"
fi
tailscale status || true

# --- inbound SSH, workers only, tailnet only ----------------------------------
SSH_FIREWALL_ENFORCED="no"
if [ "$ROLE" = "worker" ]; then
  say "inbound ssh (scoped to $TAILNET_CIDR)"
  if [ "$OS" = "Darwin" ]; then
    sudo systemsetup -setremotelogin on >/dev/null
    echo "Remote Login enabled. macOS has no per-CIDR rule here; the tailnet ACL is the boundary."
  else
    sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd
    if command -v ufw >/dev/null 2>&1; then
      sudo ufw allow from "$TAILNET_CIDR" to any port 22 proto tcp
      # Deliberately not `ufw allow ssh` — that opens 22 on hostile Wi-Fi too.
      if sudo ufw status | grep -q "^Status: active"; then
        SSH_FIREWALL_ENFORCED="yes"
      else
        echo "WARNING: ufw is installed but inactive, so the rule above is not enforced and sshd is reachable from any network. Run 'sudo ufw enable' to apply it." >&2
      fi
    else
      echo "ufw not present; scope port 22 to $TAILNET_CIDR in your firewall by hand."
    fi
  fi
  # Key-only auth. Password SSH on a laptop that roams is not defensible.
  SSHD_DROPIN=/etc/ssh/sshd_config.d/10-tailnet.conf
  if [ -d /etc/ssh/sshd_config.d ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee "$SSHD_DROPIN" >/dev/null
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
  else
    echo "WARNING: /etc/ssh/sshd_config.d not found; PasswordAuthentication was NOT disabled. Edit sshd_config by hand to add 'PasswordAuthentication no'." >&2
  fi
fi

# --- report -------------------------------------------------------------------
say "capability report"
IP="$(tailscale ip -4 2>/dev/null | head -1 || echo unknown)"
printf 'hostname        %s\n' "$HOSTNAME_NEW"
printf 'os              %s\n' "$OS"
printf 'role            %s\n' "$ROLE"
printf 'tailscale ip    %s\n' "$IP"
printf 'tag             %s\n' "${TAG:-none}"
if [ "$ROLE" != "worker" ]; then
  SSH_REPORT="no"
elif [ "$OS" = "Darwin" ]; then
  SSH_REPORT="yes, ACL-only (no host firewall CIDR scoping on macOS)"
elif [ "$SSH_FIREWALL_ENFORCED" = "yes" ]; then
  SSH_REPORT="yes, $TAILNET_CIDR enforced by ufw"
else
  SSH_REPORT="yes, ACL-only ($TAILNET_CIDR intended but NOT enforced by a host firewall)"
fi
printf 'inbound ssh     %s\n' "$SSH_REPORT"
printf 'runner capable  %s\n' "$([ "$ROLE" = worker ] && echo "yes, native" || echo no)"

if tailscale status 2>&1 | grep -qi "health check\|failed to set the DNS"; then
  printf '\nWARNING: tailscale reports a health issue above. If it mentions DNS,\n'
  printf 'MagicDNS names will not resolve from this machine — use 100.x addresses.\n'
fi

cat <<EOF

Next, by hand, once:
  1. Admin console -> this machine -> Disable key expiry. Node keys expire after
     180 days and a headless worker drops off the tailnet without telling anyone.
  2. Add the CONTROLLER's public key to this machine's authorized_keys.
     Do not generate a key here that points back at the controller.
  3. Runners and checkouts: see scripts/self-hosted-runner-fleet.
EOF
