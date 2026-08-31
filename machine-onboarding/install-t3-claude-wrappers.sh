#!/usr/bin/env bash
# install-t3-claude-wrappers.sh — write the T3 Code Claude provider wrappers to
# ~/.local/bin on this laptop. The laptop analogue of box-setup/install-agent-clis.sh.
#
# WHY: T3 Code auths each Claude provider off the macOS Keychain OAuth session,
# which expires and cannot refresh ("oauth session expired and could not be
# refreshed"). Each wrapper instead injects a 1-year `claude setup-token` value,
# so a T3 thread runs for a year with no refresh. Point each T3 provider's
# binaryPath at its wrapper (Settings -> provider -> binaryPath).
#
# NO SECRETS LIVE IN THIS FILE. Tokens are read at runtime from:
#   ~/Documents/Personal/.agents/.env.local  (600)
#     CLAUDE_CODE_OAUTH_TOKEN     -> .claude-personal   (pooria@beeloud.xyz)
#     CLAUDE_CODE_OAUTH_TOKEN_2   -> .claude-personal-1 (hello@beeloud.xyz)
#     CLAUDE_CODE_OAUTH_TOKEN_3   -> .claude-personal-2 (pooria.arab+claude@gmail.com)
# Rotate a token by editing that one file; the wrappers do not change.
#
# Idempotent: safe to re-run. Never writes a work profile (.claude = Mozilla).
set -euo pipefail

BIN="$HOME/.local/bin"
ENVF="$HOME/Documents/Personal/.agents/.env.local"
CLAUDEBIN="$HOME/.local/bin/claude"
mkdir -p "$BIN"

write() { # <name> <config-dir> <token-var> <label>
  local name="$1" dir="$2" var="$3" label="$4"
  cat > "$BIN/$name" <<WRAP
#!/usr/bin/env bash
# $name — T3 Code provider wrapper. Claude Code pinned to \$HOME/$dir
# ($label) on its own 1-year setup-token, so T3 never depends on the
# keychain OAuth session (which expires and cannot refresh).
# Rotate the token by editing ONE file: $ENVF
set -uo pipefail
ENVF="$ENVF"
unset $var
[ -f "\$ENVF" ] && . "\$ENVF"
TOK="\${$var:-}"
if [ -z "\$TOK" ]; then
  echo "$name: no $var in \$ENVF — refusing to fall through to the wrong subscription." >&2
  exit 1
fi
exec env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \\
  -u OFFROUTER_HOME -u OFFROUTER_PROFILE \\
  CLAUDE_CODE_OAUTH_TOKEN="\$TOK" \\
  CLAUDE_CONFIG_DIR="\$HOME/$dir" \\
  "$CLAUDEBIN" "\$@"
WRAP
  chmod +x "$BIN/$name"
  echo "wrote $BIN/$name -> \$HOME/$dir ($label, \$$var)"
}

write claude-t3-personal   .claude-personal   CLAUDE_CODE_OAUTH_TOKEN   "pooria@beeloud.xyz"
write claude-t3-personal-1 .claude-personal-1 CLAUDE_CODE_OAUTH_TOKEN_2 "hello@beeloud.xyz"
write claude-t3-personal-2 .claude-personal-2 CLAUDE_CODE_OAUTH_TOKEN_3 "pooria.arab+claude@gmail.com"

echo "done. In T3: Settings -> each Claude provider -> set binaryPath to the wrapper above."
