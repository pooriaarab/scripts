#!/usr/bin/env bash
# Assert the flags each launcher cannot work without.
#
# These are not style checks. Every flag below was added after a route was
# reported dead and turned out to be healthy: the run either blocked forever,
# refused every write while exiting 0, or authenticated against the wrong
# credentials. A launcher missing one of them fails in a way that reads as the
# provider's fault, so the flags are pinned here rather than trusted to review.
#
# The assertions read the launcher SOURCE. Executing these routes costs money
# and needs network, so what is checked is the invocation each one builds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0

# Match the CODE, never the comments. Every one of these flags is also
# explained in a comment in the file it belongs to, so grepping the whole file
# passes on a launcher that documents a flag and does not pass it -- which is
# exactly the state one of these was in before this test existed.
code() { grep -vE '^[[:space:]]*#' "$HERE/$1"; }

want() {
  local file="$1" pattern="$2" why="$3"
  if code "$file" | grep -qE -- "$pattern"; then
    printf 'ok    %s: %s\n' "$file" "$why"
  else
    printf 'FAIL  %s: %s (no match for %s)\n' "$file" "$why" "$pattern"
    fails=$((fails + 1))
  fi
}

deny() {
  local file="$1" pattern="$2" why="$3"
  if code "$file" | grep -qE -- "$pattern"; then
    printf 'FAIL  %s: %s (matched %s)\n' "$file" "$why" "$pattern"
    fails=$((fails + 1))
  else
    printf 'ok    %s: %s\n' "$file" "$why"
  fi
}

# Muse: the default approval mode blocks forever headless, with no model output.
want w-muse '--approval-mode never'        'never waits on an approval prompt'
want w-muse '--user-input-auto-resolve'    'cancels a user-input request'
want w-muse '--trust-workspace'            'loads the repo AGENTS.md'

# Devin: accept-edits refuses every shell call and still exits 0; and the
# secrets file overrides the working OAuth, which surfaces as resource_exhausted.
want w-devin '--permission-mode dangerous' 'can run its own tests'
want w-devin '\-p -- '                     'passes the prompt after --'
want w-devin 'env -u DEVIN_API_KEY'        'unsets the key that shadows OAuth'
deny w-devin '^[[:space:]]*\.[[:space:]]+"\$SECRETS"' 'does not source devin.env'
deny w-devin 'set -a'                      'does not export the secrets file'

# Cursor: --trust alone leaves every shell command refused, so the agent cannot
# read the issue it was told to implement and writes to the prompt instead.
want w-cursor '--force'                    'shell calls are allowed'

# Gemini: refuses outright without it.
want w-gemini '--skip-trust'               'runs outside a trusted directory'

[ "$fails" = 0 ] || { printf '\n%s failing\n' "$fails" >&2; exit 1; }
printf '\nall passing\n'
