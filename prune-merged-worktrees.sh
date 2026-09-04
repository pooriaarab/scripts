#!/usr/bin/env bash
# prune-merged-worktrees.sh — remove linked worktrees whose branches merged.
# Usage: prune-merged-worktrees.sh [repo-path] [--apply]
# Default is dry-run. Pass --apply to actually remove worktrees.
set -euo pipefail

# --- Args ---
REPO="."
APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      echo "Usage: $0 [repo-path] [--apply]"
      exit 0
      ;;
    *) REPO="$arg" ;;
  esac
done

cd "$REPO"

# --- Preconditions ---
command -v git >/dev/null || { echo "error: git not found" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "error: not a git repo: $REPO" >&2; exit 1; }

MAIN_TOP="$(git rev-parse --show-toplevel)"
# Scratch files that alone do not block removal.
SCRATCH_RE='^(WORKER_BRIEF\.md|CONTINUE\.md|BRIEF\.md)$'

removed=0
skipped=0
needs_review=0
removed_list=()
skipped_list=()
review_list=()

# --- Enumerate linked worktrees via porcelain output ---
# Blocks look like: "worktree <path>", "branch refs/heads/<name>", ...
current_path=""
current_branch=""
process_worktree() {
  [ -n "$current_path" ] || return 0
  local wt="$current_path" br="$current_branch"
  current_path=""; current_branch=""

  # Skip the main worktree itself.
  if [ "$wt" = "$MAIN_TOP" ]; then
    return 0
  fi

  # SAFETY: verify this is a genuine LINKED worktree before touching it.
  # A linked worktree's gitdir lives under <main>/.git/worktrees/<name>.
  # A main clone's gitdir is <dir>/.git — never delete those.
  local gitdir
  if ! gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"; then
    skipped_list+=("$wt (not a git worktree)")
    skipped=$((skipped + 1))
    return 0
  fi
  case "$gitdir" in
    *"/worktrees/"*) ;; # genuine linked worktree, proceed
    *)
      skipped_list+=("$wt (main clone, gitdir=$gitdir)")
      skipped=$((skipped + 1))
      return 0
      ;;
  esac

  # Detached HEAD (no branch line) cannot prove merged status — skip.
  if [ -z "$br" ] || [ "$br" = "(detached)" ]; then
    skipped_list+=("$wt (detached HEAD)")
    skipped=$((skipped + 1))
    return 0
  fi
  local short="${br#refs/heads/}"

  # --- Merged check: branch merged into origin/main (or local main)? ---
  local merged=0
  # Refresh remote tracking ref quietly; ignore fetch failures (offline).
  git fetch origin main --quiet 2>/dev/null || true
  # Prefer origin/main; fall back to local main/master when no remote exists.
  local intobranch="origin/main"
  if ! git rev-parse --verify --quiet "$intobranch" >/dev/null; then
    if git rev-parse --verify --quiet "refs/heads/main" >/dev/null; then
      intobranch="main"
    elif git rev-parse --verify --quiet "refs/heads/master" >/dev/null; then
      intobranch="master"
    fi
  fi
  if git branch --merged "$intobranch" --format='%(refname)' 2>/dev/null | grep -qx "refs/heads/$short"; then
    merged=1
  elif command -v gh >/dev/null 2>&1; then
    # Fall back to PR state when the local merged test fails.
    local state
    state="$(gh pr view "$short" --json state -q .state 2>/dev/null || true)"
    if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
      merged=1
    fi
  fi
  if [ "$merged" -eq 0 ]; then
    skipped_list+=("$wt ($short not merged)")
    skipped=$((skipped + 1))
    return 0
  fi

  # --- Cleanliness check ---
  local status real_dirty=0
  status="$(git -C "$wt" status --porcelain 2>/dev/null || echo "__ERROR__")"
  if [ "$status" = "__ERROR__" ]; then
    review_list+=("$wt ($short status unreadable)")
    needs_review=$((needs_review + 1))
    return 0
  fi
  if [ -n "$status" ]; then
    # Any changed path outside the scratch set counts as real.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Porcelain v1: XY + space + path (handle renames "old -> new").
      local f="${line:3}"
      f="${f##* -> }"
      f="$(basename "$f")"
      if ! printf '%s' "$f" | grep -Eq "$SCRATCH_RE"; then
        real_dirty=1
        break
      fi
    done <<< "$status"
  fi
  if [ "$real_dirty" -eq 1 ]; then
    # Real changes: never delete. Report for manual salvage
    # (commit to a salvage branch and push).
    review_list+=("$wt ($short merged but has real changes)")
    needs_review=$((needs_review + 1))
    return 0
  fi

  # --- Safe to remove (or dry-run report) ---
  if [ "$APPLY" -eq 1 ]; then
    # Never rm -rf as a fallback: git owns removal or nothing happens.
    if git worktree remove "$wt"; then
      removed_list+=("$wt ($short)")
      removed=$((removed + 1))
    else
      review_list+=("$wt ($short remove failed)")
      needs_review=$((needs_review + 1))
    fi
  else
    removed_list+=("$wt ($short) [dry-run]")
    removed=$((removed + 1))
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) process_worktree; current_path="${line#worktree }" ;;
    "branch "*)   current_branch="${line#branch }" ;;
    "detached")   current_branch="(detached)" ;;
  esac
done < <(git worktree list --porcelain)
process_worktree # flush last entry

# --- Summary ---
echo "== worktree hygiene =="
echo "repo: $MAIN_TOP"
if [ "$APPLY" -eq 1 ]; then echo "mode: apply"; else echo "mode: dry-run (pass --apply to remove)"; fi
echo "removed: $removed"
for x in ${removed_list[@]+"${removed_list[@]}"}; do echo "  - $x"; done
echo "skipped: $skipped"
for x in ${skipped_list[@]+"${skipped_list[@]}"}; do echo "  - $x"; done
echo "needs-review: $needs_review"
for x in ${review_list[@]+"${review_list[@]}"}; do echo "  - $x"; done
