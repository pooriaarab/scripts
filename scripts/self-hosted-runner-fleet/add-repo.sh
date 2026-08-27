#!/usr/bin/env bash
# Add a private repository to a self-hosted runner fleet host, or prepare that host.
# Configure with RUNNER_SSH_TARGET, RUNNER_SSH_KEY, RUNNER_NAME, RUNNER_LABEL, and
# RUNNER_WSL_DISTRO when the runner lives inside WSL2 on a Windows machine.
set -euo pipefail

: "${RUNNER_SSH_TARGET:?export RUNNER_SSH_TARGET=user@host}"
: "${RUNNER_NAME:?export RUNNER_NAME=RUNNER-NAME}"
: "${RUNNER_LABEL:?export RUNNER_LABEL=your-label}"
[[ "$RUNNER_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "RUNNER_NAME must match [A-Za-z0-9_-]+" >&2; exit 2; }
[[ "$RUNNER_LABEL" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "RUNNER_LABEL must match [A-Za-z0-9_-]+" >&2; exit 2; }
ssh_key="${RUNNER_SSH_KEY:-$HOME/.ssh/id_ed25519}"
wsl_distro="${RUNNER_WSL_DISTRO:-}"
service_user="${RUNNER_SERVICE_USER:-actions}"
install_root="${RUNNER_INSTALL_ROOT:-/opt/actions-runner}"
version="${RUNNER_VERSION:-2.337.0}"

usage() {
  cat <<'USAGE'
Usage: add-repo.sh <command> [args]
  prepare-host                 apply host prerequisites (idempotent)
  register <owner/repo> [n]    register runner service n for the repository
  status <owner/repo>          report the repository's runners
  list                         runner services on the host
USAGE
}

require_private() {
  [[ "$(gh repo view "$1" --json isPrivate --jq .isPrivate)" == true ]] || {
    echo "Refusing: $1 is public. A public repository can run a fork's code on your host." >&2
    exit 2
  }
}

# base64 keeps PowerShell (the usual Windows OpenSSH shell) and WSL from mangling quotes.
# Piped through ssh's stdin rather than spliced into the remote command line: the
# registration token lands in this payload, and a command-line argument sits in `ps`
# output (readable by any other local user on the runner host) for as long as the
# registration takes, not just the moment it's used.
remote_bash() {
  if [[ -n "$wsl_distro" ]]; then
    base64 | ssh -i "$ssh_key" -o IdentitiesOnly=yes -o BatchMode=yes "$RUNNER_SSH_TARGET" \
      "wsl.exe -d $wsl_distro --user root -- bash -lc 'base64 -d | bash'"
  else
    base64 | ssh -i "$ssh_key" -o IdentitiesOnly=yes -o BatchMode=yes "$RUNNER_SSH_TARGET" \
      "sudo -n bash -lc 'base64 -d | bash'"
  fi
}

register() {
  local repo="$1" instance="${2:-1}" name dir svc
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "owner/repo must match [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+" >&2; exit 2; }
  [[ "$instance" =~ ^[0-9]+$ ]] || { echo "instance must be a positive integer" >&2; exit 2; }
  require_private "$repo"
  name="${repo#*/}"
  if [[ "$instance" == 1 ]]; then dir="$install_root/$name"; svc="$RUNNER_NAME"
  else dir="$install_root/$name-$instance"; svc="$RUNNER_NAME-$instance"; fi
  local tarball="actions-runner-linux-x64-$version.tar.gz" token
  # Short-lived registration token. Never echo it.
  token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)"
  # The directory and token are inlined: `su` starts a fresh shell that does not inherit
  # this script's variables, and referencing them there installs into the wrong place with
  # an empty token.
  remote_bash <<REMOTE
set -euo pipefail
test ! -e '$dir' || { echo 'Runner already exists: $dir' >&2; exit 1; }
trap "rm -rf '$dir'" ERR
install -d -o $service_user -g $service_user '$dir' '$dir/home'
su $service_user -s /bin/bash -c 'cd $dir \
&& curl -fsSLO https://github.com/actions/runner/releases/download/v$version/$tarball \
&& tar xzf $tarball && rm $tarball \
&& ./config.sh --unattended --url https://github.com/$repo --token $token \
--name $svc --labels $RUNNER_LABEL --work _work --replace'
trap - ERR
cd '$dir'
./svc.sh install $service_user
mapfile -t units < <(systemctl list-unit-files 'actions.runner.*' --no-legend | awk '{print \$1}' | grep -F '.$svc.service')
if [ "\${#units[@]}" -ne 1 ]; then
  echo "Expected exactly one unit matching .$svc.service, found \${#units[@]}" >&2
  exit 1
fi
unit="\${units[0]}"
install -d "/etc/systemd/system/\$unit.d"
printf '[Service]\nEnvironment=HOME=%s\n' '$dir/home' > "/etc/systemd/system/\$unit.d/home.conf"
systemctl daemon-reload
systemctl restart "\$unit"
systemctl is-active "\$unit"
REMOTE
  status "$repo"
}

status() { gh api "repos/$1/actions/runners" --jq '.runners[]|{name,status,busy,labels:[.labels[].name]}'; }

prepare_host() {
  remote_bash <<REMOTE
set -euo pipefail
user='$service_user'; root='$install_root'
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "\$user" > /etc/sudoers.d/actions-runner
chmod 0440 /etc/sudoers.d/actions-runner
visudo -c -q -f /etc/sudoers.d/actions-runner
echo "sudo: passwordless for \$user"
major="\$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"
if [ -z "\$major" ] || [ "\$major" -lt 22 ]; then
  echo "node: \${major:-missing} is older than the hosted images; wrangler and friends will fail here only"
else
  echo "node: v\$major"
fi
for unit in \$(systemctl list-unit-files 'actions.runner.*' --no-legend | awk '{print \$1}'); do
  dir="\$(sed -n 's/^WorkingDirectory=//p' "/etc/systemd/system/\$unit" | head -1)"
  case "\$dir" in "\$root"/*) ;; *) continue ;; esac
  install -d -o "\$user" -g "\$user" "\$dir/home"
  install -d "/etc/systemd/system/\$unit.d"
  printf '[Service]\nEnvironment=HOME=%s\n' "\$dir/home" > "/etc/systemd/system/\$unit.d/home.conf"
done
systemctl daemon-reload
echo "home: split per runner service (restart the services to pick it up)"
REMOTE
}

case "${1:-}" in
  prepare-host) prepare_host ;;
  register) shift; register "${1:?owner/repo}" "${2:-1}" ;;
  status) shift; status "${1:?owner/repo}" ;;
  list) remote_bash <<<"systemctl list-units 'actions.runner.*' --no-legend --all | awk '{print \$1, \$4}'" ;;
  *) usage >&2; exit 2 ;;
esac
