#!/usr/bin/env bash
# install-agent-clis.sh — provision the personal agent-CLI roster on an ascii.dev Box.
#
# Installs and wires: claude (3 subscription profiles), codex, gemini, kimi, pi, muse, cursor-agent, devin.
# Idempotent: safe to re-run. Never fails the whole run on one CLI; it reports per CLI.
#
# NO SECRETS LIVE IN THIS FILE. Credentials arrive out of band, through
# `box env set-file`, at these in-box paths:
#
#   ~/.agents/agent-clis.env       CLAUDE_CODE_OAUTH_TOKEN[_2|_3], GEMINI_API_KEY, CURSOR_API_KEY
#   ~/.gemini-personal/.gemini/.env   GEMINI_API_KEY
#   ~/.pi/agent/auth.json         pi provider keys (openrouter, zai, ...)
#   ~/.kimi-code/config.toml      Moonshot API key + model table
#   ~/.config/muse/auth.json      Meta Muse OAuth
#   ~/.codex-personal/auth.json   optional; falls back to the box-injected ~/.codex/auth.json
#   ~/.config/devin/config.json   devin configuration (default model)
#   ~/.local/share/devin/credentials.toml   devin credentials (written by devin auth login)
#
# Usage:  box new --environment <env> --setup-file box-setup/install-agent-clis.sh

set -uo pipefail

BIN="$HOME/.local/bin"
# Install npm globals outside nvm. A box built from a snapshot can boot with a
# different node on PATH than the box the snapshot came from, and anything
# installed into ~/.nvm/versions/node/<v>/bin then disappears.
# Pass --prefix per install rather than `npm config set prefix`: the latter
# writes ~/.npmrc, and nvm warns on every shell when it finds a prefix there.
NPM_PREFIX="$HOME/.npm-global"
mkdir -p "$BIN" "$HOME/.agents" "$NPM_PREFIX"
npm config delete prefix >/dev/null 2>&1
export PATH="$HOME/.kimi-code/bin:$BIN:$NPM_PREFIX/bin:$PATH"

STATUS_FILE="$HOME/.agents/install-status.txt"
: > "$STATUS_FILE"

log()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }
mark() { printf '%-18s %s\n' "$1" "$2" >> "$STATUS_FILE"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- npm CLIs ---
# codex and claude usually ship on the box image already; only install a gap.
npm_install() { # <bin-name> <package>
  local bin="$1" pkg="$2"
  if have "$bin"; then
    note "$bin already present ($("$bin" --version 2>&1 | head -1))"
    mark "$bin" "present"
    return 0
  fi
  note "installing $pkg"
  if npm install -g --prefix "$NPM_PREFIX" --no-fund --no-audit "$pkg" >/dev/null 2>&1 && have "$bin"; then
    mark "$bin" "installed"
  else
    mark "$bin" "FAILED (npm install $pkg)"
  fi
}

log "gemini-cli"
# gemini — needs --skip-trust or it errors "not running in a trusted directory".
# Source the personal .env, scrub Vertex vars, pin GEMINI_CLI_HOME and trust.
# GEMINI_CLI_HOME=~/.gemini-personal GEMINI_CLI_TRUST_WORKSPACE=true gemini --skip-trust --yolo -m gemini-3.8-flash -p "PROMPT"
npm_install gemini "@google/gemini-cli"

log "pi coding agent"
npm_install pi "@earendil-works/pi-coding-agent"

log "codex"
npm_install codex "@openai/codex"

# ----------------------------------------------------------------- claude ----
log "claude code"
if have claude; then
  note "claude already present ($(claude --version 2>&1 | head -1))"
  mark claude "present"
else
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1
  have claude && mark claude "installed" || mark claude "FAILED (claude.ai/install.sh)"
fi

# ------------------------------------------------------------------- kimi ----
# NOTE the URL. https://code.kimi.com/install.sh installs the DEPRECATED Python
# "kimi-cli", a different product that lands in ~/.local/bin and shadows this
# one on PATH. Kimi Code is the /kimi-code/ path and lands in ~/.kimi-code/bin.
log "kimi code"
if [ -x "$HOME/.kimi-code/bin/kimi" ]; then
  note "kimi already present ($("$HOME/.kimi-code/bin/kimi" --version 2>&1 | head -1))"
  mark kimi "present"
else
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash >/dev/null 2>&1
  if [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    mark kimi "installed"
  else
    mark kimi "FAILED (code.kimi.com/kimi-code/install.sh)"
  fi
fi

# ------------------------------------------------------------------- muse ----
# The launcher is a small bash script; it downloads the real binary on first run
# and needs ~/.config/muse/auth.json to authenticate that download.
log "muse code"
# muse — headless runs must pass --yolo, or the run can wait on an approval
# prompt with zero edits while the call still reports success.
# muse exec --yolo --json --model muse-spark-1.3-contributor --workspace <path> --prompt-file FILE
if [ -x "$BIN/muse" ]; then
  note "muse launcher already present"
  mark muse "present"
elif curl -fsSL https://api.meta.ai/muse-launcher.sh -o "$BIN/muse" && [ -s "$BIN/muse" ]; then
  chmod +x "$BIN/muse"
  mark muse "installed"
else
  rm -f "$BIN/muse"
  mark muse "FAILED (api.meta.ai/muse-launcher.sh)"
fi
# Pre-warm: the launcher downloads a ~166 MB binary on first use, which is
# longer than a `box exec` round trip. Pay that cost during setup instead.
[ -x "$BIN/muse" ] && "$BIN/muse" --version >/dev/null 2>&1

# ----------------------------------------------------------- cursor-agent ----
log "cursor-agent"
# cursor-agent — needs --trust; and the API key must be EXPORTED, not just
# sourced. The authoritative key lives in ~/.agents/cursor.env.
# set -a; source ~/.agents/cursor.env; set +a
# cursor-agent -p --trust --force --model composer-2.5 --output-format json "PROMPT"
if [ -x "$BIN/cursor-agent" ]; then
  note "cursor-agent already present ($("$BIN/cursor-agent" --version 2>&1 | head -1))"
  mark cursor-agent "present"
else
  curl -fsSL https://cursor.com/install | bash >/dev/null 2>&1
  if [ -x "$BIN/cursor-agent" ]; then
    mark cursor-agent "installed"
  else
    mark cursor-agent "FAILED (cursor.com/install)"
  fi
fi

# ------------------------------------------------------------------ devin ----
log "devin"
# devin — refuses an untrusted workspace headless; needs both flags to write.
# The verified route is the personal login with API env vars unset; the
# credentials file is required and API keys alone do not authenticate.
# env -u DEVIN_API_KEY -u DEVIN_TOKEN -u WINDSURF_API_KEY devin --model swe-1.7 --respect-workspace-trust false --permission-mode dangerous -p "PROMPT"
# (--prompt-file FILE -p also works.)
if [ -x "$BIN/devin" ]; then
  note "devin already present ($("$BIN/devin" --version 2>&1 | head -1))"
  mark devin "present"
else
  # The official installer verifies its artifact checksum and installs the
  # binary, then can exit nonzero from its interactive setup step. Judge by
  # the binary on disk, not by that exit code.
  curl -fsSL https://cli.devin.ai/install.sh | bash >/dev/null 2>&1
  installer_rc=$?
  if [ -x "$BIN/devin" ]; then
    mark devin "installed"
    (( installer_rc )) && note "devin installer exited $installer_rc after installing the binary (interactive setup); binary validated"
  else
    mark devin "FAILED (cli.devin.ai/install.sh exit $installer_rc, no binary at $BIN/devin)"
  fi
fi

# --------------------------------------------------------- codex-personal ----
# The box image injects the owner's own ChatGPT credential at ~/.codex/auth.json.
# Copy it into CODEX_HOME=~/.codex-personal when no explicit seed is present, so
# the personal profile is authenticated without duplicating a refresh token into
# the environment store. An explicit seed always wins.
log "codex-personal profile"
mkdir -p "$HOME/.codex-personal"
if [ -s "$HOME/.codex-personal/auth.json" ]; then
  note "seeded ~/.codex-personal/auth.json present"
elif [ -s "$HOME/.codex/auth.json" ]; then
  cp "$HOME/.codex/auth.json" "$HOME/.codex-personal/auth.json"
  chmod 600 "$HOME/.codex-personal/auth.json"
  note "copied box-injected ~/.codex/auth.json into ~/.codex-personal"
else
  note "WARNING no codex credential found"
fi

# -------------------------------------------------------- gemini-personal ----
# GEMINI_CLI_HOME relocates config to $DIR/.gemini. Pin API-key auth; the laptop
# uses personal Vertex ADC, which is deliberately NOT shipped to a sandbox.
log "gemini-personal profile"
mkdir -p "$HOME/.gemini-personal/.gemini"
if [ ! -s "$HOME/.gemini-personal/.gemini/settings.json" ]; then
  cat > "$HOME/.gemini-personal/.gemini/settings.json" <<'JSON'
{
  "security": { "auth": { "selectedType": "gemini-api-key" } },
  "ui": { "theme": "Default" }
}
JSON
fi

# --------------------------------------------------------------- pi routes ----
# Register the zai-api provider (metered z.ai endpoint). The Coding Plan
# provider `zai` is a separate, subscription-billed route and can expire; the
# `zai-api` override reuses the same stored key against the pay-as-you-go
# endpoint. The key is read at call time from pi's own auth store, so no secret
# lands in this file.
#
# Also cap openrouter's deepseek/deepseek-v3.2 output. pi's bundled catalog
# declares maxTokens=163840 for that model while OpenRouter reports
# max_completion_tokens=65536, and an unconstrained request asked for 153497
# output tokens and failed. The override below pins maxTokens=8192.
log "pi provider overrides"
mkdir -p "$HOME/.pi/agent"
if [ ! -s "$HOME/.pi/agent/models.json" ]; then
  cat > "$HOME/.pi/agent/models.json" <<'JSON'
{
  "providers": {
    "zai-api": {
      "baseUrl": "https://api.z.ai/api/paas/v4",
      "api": "openai-completions",
      "apiKey": "!bash -lc \"pi auth print-api-key --provider zai\"",
      "models": [
        { "id": "glm-5.3-flash", "name": "GLM 5.3 Flash (API)", "contextWindow": 204800, "maxTokens": 16384, "reasoning": true, "input": ["text"] },
        { "id": "glm-5.3", "name": "GLM 5.3 (API)", "contextWindow": 204800, "maxTokens": 16384, "reasoning": true, "input": ["text"] },
        { "id": "glm-5.2", "name": "GLM 5.2 (API)", "contextWindow": 204800, "maxTokens": 16384, "reasoning": true, "input": ["text"] }
      ]
    },
    "openrouter": {
      "modelOverrides": {
        "deepseek/deepseek-v3.2": { "maxTokens": 8192 }
      }
    }
  }
}
JSON
  note "wrote ~/.pi/agent/models.json"
else
  note "~/.pi/agent/models.json already present, left alone"
fi

# --------------------------------------------------------------- wrappers ----
# One wrapper per named profile, mirroring the laptop shell functions. Each one
# pins its config dir and injects its OWN token. A wrapper FAILS LOUDLY rather
# than falling through to whatever credential the platform put in the
# environment: a silent fallback to the wrong subscription is the bug this
# whole layout exists to prevent.
log "profile wrappers"

write_claude_wrapper() { # <wrapper-name> <config-dir-suffix> <token-var>
  local name="$1" dir="$2" var="$3"
  cat > "$BIN/$name" <<WRAP
#!/usr/bin/env bash
# $name — Claude Code pinned to \$HOME/$dir on its own subscription token.
set -uo pipefail
ENVF="\$HOME/.agents/agent-clis.env"
[ -f "\$ENVF" ] && . "\$ENVF"
TOK="\${$var:-}"
if [ -z "\$TOK" ]; then
  echo "$name: no $var in \$ENVF." >&2
  echo "$name: refusing to run on the box-injected CLAUDE_CODE_OAUTH_TOKEN, which is a different profile." >&2
  exit 1
fi
mkdir -p "\$HOME/$dir"
exec env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \\
  CLAUDE_CODE_OAUTH_TOKEN="\$TOK" \\
  CLAUDE_CONFIG_DIR="\$HOME/$dir" \\
  CODEX_HOME="\$HOME/.codex-personal" \\
  GEMINI_CLI_HOME="\$HOME/.gemini-personal" \\
  claude "\$@"
WRAP
  chmod +x "$BIN/$name"
  note "wrote $name -> \$HOME/$dir"
}

write_claude_wrapper claude-personal   .claude-personal   CLAUDE_CODE_OAUTH_TOKEN
write_claude_wrapper claude-personal-1 .claude-personal-1 CLAUDE_CODE_OAUTH_TOKEN_2
write_claude_wrapper claude-personal-2 .claude-personal-2 CLAUDE_CODE_OAUTH_TOKEN_3

cat > "$BIN/codex-personal" <<'WRAP'
#!/usr/bin/env bash
# codex-personal — Codex CLI pinned to CODEX_HOME=$HOME/.codex-personal.
# OPENAI_API_KEY is scrubbed so the ChatGPT-subscription auth.json is used, not
# whatever key happens to be in the environment.
set -uo pipefail
if [ ! -s "$HOME/.codex-personal/auth.json" ]; then
  echo "codex-personal: no ~/.codex-personal/auth.json — run the setup script." >&2
  exit 1
fi
# `codex exec` refuses to run outside a git repo unless told to. A box scratch
# dir is often not a repo, so add the flag when it is both needed and absent.
if [ "${1:-}" = "exec" ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  case " $* " in
    *" --skip-git-repo-check "*) ;;
    *) shift; set -- exec --skip-git-repo-check "$@" ;;
  esac
fi
exec env -u OPENAI_API_KEY -u OPENAI_BASE_URL CODEX_HOME="$HOME/.codex-personal" codex "$@"
WRAP
chmod +x "$BIN/codex-personal"
note "wrote codex-personal -> CODEX_HOME=\$HOME/.codex-personal"

cat > "$BIN/gemini-personal" <<'WRAP'
#!/usr/bin/env bash
# gemini-personal — Gemini CLI pinned to GEMINI_CLI_HOME=$HOME/.gemini-personal.
# Vertex env is scrubbed so it uses the personal API key, not any ambient ADC.
set -uo pipefail
ENVF="$HOME/.agents/agent-clis.env"
[ -f "$ENVF" ] && . "$ENVF"
KEY="${GEMINI_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HOME/.gemini-personal/.gemini/.env" ]; then
  . "$HOME/.gemini-personal/.gemini/.env"
  KEY="${GEMINI_API_KEY:-}"
fi
if [ -z "$KEY" ]; then
  echo "gemini-personal: no GEMINI_API_KEY in ~/.agents/agent-clis.env or ~/.gemini-personal/.gemini/.env" >&2
  exit 1
fi
# The box IS the sandbox, so trust it by default; still overridable.
exec env -u GOOGLE_GENAI_USE_VERTEXAI -u GOOGLE_APPLICATION_CREDENTIALS \
  -u GOOGLE_CLOUD_PROJECT -u GOOGLE_CLOUD_LOCATION \
  GEMINI_CLI_HOME="$HOME/.gemini-personal" GEMINI_API_KEY="$KEY" \
  GEMINI_CLI_TRUST_WORKSPACE="${GEMINI_CLI_TRUST_WORKSPACE:-true}" \
  gemini "$@"
WRAP
chmod +x "$BIN/gemini-personal"
note "wrote gemini-personal -> GEMINI_CLI_HOME=\$HOME/.gemini-personal"

# -------------------------------------------------------------- shell PATH ----
log "shell PATH"
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || touch "$rc"
  grep -q 'agent-cli roster PATH' "$rc" 2>/dev/null || cat >> "$rc" <<'RC'
# agent-cli roster PATH
export PATH="$HOME/.kimi-code/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
# Prefer the newest nvm node; a snapshot can boot on an older system node.
for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && NVM_NEWEST="$d"
done
[ -n "${NVM_NEWEST:-}" ] && export PATH="$NVM_NEWEST:$PATH"
RC
done

# ------------------------------------------------------------------ report ----
log "installed"
for f in "$HOME/.agents/agent-clis.env" "$HOME/.pi/agent/auth.json" \
         "$HOME/.kimi-code/config.toml" "$HOME/.config/muse/auth.json" \
         "$HOME/.gemini-personal/.gemini/.env" "$HOME/.codex-personal/auth.json" \
         "$HOME/.config/devin/config.json" "$HOME/.local/share/devin/credentials.toml"; do
  if [ -s "$f" ]; then mark "cred:$(basename "$(dirname "$f")")/$(basename "$f")" "present"
  else mark "cred:$(basename "$(dirname "$f")")/$(basename "$f")" "MISSING"; fi
done
cat "$STATUS_FILE"
echo
echo "agent-cli roster setup complete"
