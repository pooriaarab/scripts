#!/usr/bin/env bash
# Bootstrap a remote agent dev box: base toolchain, agent CLIs, per-provider
# config dirs. Idempotent -- safe to re-run after a partial failure.
#
# Usage (as a non-root sudoer, on a fresh Ubuntu 24.04 box):
#   curl -fsSL <raw-url>/bootstrap.sh | bash
#   # or: scp it over, then: bash bootstrap.sh
#
# Deliberately does NOT log any agent in. Logins are interactive and need a
# browser callback -- see README.md "Phase 3".

set -uo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] && { echo "Run as a normal sudoer, not root."; exit 1; }

NODE_MAJOR=25
MISSING=()

log "Base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential git curl wget unzip zip jq ripgrep fd-find tmux htop \
  ca-certificates gnupg python3 python3-pip pkg-config libssl-dev \
  ufw fail2ban unattended-upgrades

log "Swap (Next/OpenNext builds ask for an 8 GB heap)"
if ! swapon --show | grep -q /swapfile; then
  if sudo fallocate -l 16G /swapfile \
    && sudo chmod 600 /swapfile \
    && sudo mkswap -q /swapfile \
    && sudo swapon /swapfile; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  else
    warn "swap setup failed, leaving /etc/fstab untouched"
    sudo rm -f /swapfile
  fi
fi

log "Firewall + SSH hardening"
sudo ufw --force default deny incoming
sudo ufw --force default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh || sudo systemctl reload sshd

log "GitHub CLI"
if ! have gh; then
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh
fi

log "Node ${NODE_MAJOR} via fnm"
if ! have fnm; then
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fi
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)" 2>/dev/null || true
fnm install "$NODE_MAJOR" >/dev/null 2>&1 || warn "fnm install $NODE_MAJOR failed"
fnm default "$NODE_MAJOR" >/dev/null 2>&1 || true
eval "$(fnm env --shell bash)" 2>/dev/null || true

log "Bun"
have bun || curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"

log "Agent CLIs"
npm_i() { npm install -g "$1" >/dev/null 2>&1 && echo "  ok   $1" || { echo "  FAIL $1"; MISSING+=("$1"); }; }
npm_i @anthropic-ai/claude-code
npm_i @google/gemini-cli
npm_i @openai/codex

# Superset host server -- Linux x64 + arm64 binaries exist.
if ! have superset; then
  curl -fsSL https://superset.sh/install.sh | bash \
    && echo "  ok   superset" || { echo "  FAIL superset"; MISSING+=(superset); }
fi

# These three ship their own installers and I have NOT verified a Linux build
# exists for each. Install by hand; the box is useful without them.
for c in kimi muse pi; do
  have "$c" || { echo "  todo $c (install manually, see README Phase 2b)"; MISSING+=("$c"); }
done

log "Per-provider config dirs (mirrors the laptop work/personal split)"
mkdir -p ~/.claude-personal ~/.claude-personal-1 ~/.codex-personal ~/.gemini-personal
if [[ -f ~/.agentrc ]]; then
  warn "~/.agentrc already exists, leaving it as-is (it may hold SUPERSET_API_KEY or other local edits)"
else
  cat > ~/.agentrc <<'RC'
# Sourced by ~/.bashrc. One config dir per identity so provider credentials
# never mix. Matches the laptop layout.
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.superset/bin:$HOME/.kimi-code/bin:$PATH"
export CODEX_HOME="$HOME/.codex-personal"
export GEMINI_CLI_HOME="$HOME/.gemini-personal"

claude-personal()   { CLAUDE_CONFIG_DIR="$HOME/.claude-personal"   command claude "$@"; }
claude-personal-1() { CLAUDE_CONFIG_DIR="$HOME/.claude-personal-1" command claude "$@"; }
RC
fi
grep -q 'agentrc' ~/.bashrc || cat >> ~/.bashrc <<'RC'

eval "$(fnm env --shell bash)" 2>/dev/null || true
[ -f "$HOME/.agentrc" ] && . "$HOME/.agentrc"
RC

log "Verify"
# shellcheck disable=SC1090
. ~/.agentrc
for c in git gh node bun claude codex gemini superset kimi muse pi; do
  printf '  %-10s %s\n' "$c" "$(command -v $c 2>/dev/null || echo MISSING)"
done
printf '  %-10s %s\n' "disk" "$(df -h --output=avail / | tail -1 | tr -d ' ') free"
printf '  %-10s %s\n' "ram" "$(free -g | awk '/^Mem:/{print $2"Gi"}')"

if ((${#MISSING[@]})); then
  warn "not installed: ${MISSING[*]}"
fi
log "Done. Next: log each agent in (README Phase 3), then start Superset (Phase 4)."
