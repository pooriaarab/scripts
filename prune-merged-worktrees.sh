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

# Capture the worktree list once: reused below for MAIN_TOP and the
# enumeration loop, and lets us fail loudly if the command itself fails
# (a `while ... < <(cmd)` would otherwise silently see zero lines).
WT_PORCELAIN="$(git worktree list --porcelain)" || { echo "error: git worktree list failed" >&2; exit 1; }
# The main worktree is always the first entry, regardless of which
# worktree $REPO happens to point at (git rev-parse --show-toplevel would
# instead report whichever worktree we're standing in).
MAIN_TOP="${WT_PORCELAIN%%$'\n'*}"
MAIN_TOP="${MAIN_TOP#worktree }"
# The shared gitdir every linked worktree hangs off of, as
# "<common-git-dir>/worktrees/<name>". Resolved once, absolute, so the
# per-worktree check below can't be fooled by an unrelated repo whose own
# path merely contains the substring "/worktrees/" (see below).
COMMON_GITDIR="$(git rev-parse --git-common-dir)"
COMMON_GITDIR="$(cd "$COMMON_GITDIR" && pwd -P)"
# Re-anchor our own cwd to the main worktree, which process_worktree never
# removes. Without this, if $REPO itself is a linked worktree that turns
# out to be eligible for removal, `git worktree remove` deletes the
# directory the shell is sitting in, and every subsequent ambient `git`
# call (rev-parse, branch --merged, worktree remove for later entries)
# fails because the shell can no longer resolve its own cwd.
cd "$MAIN_TOP"
# Scratch files that alone do not block removal.
SCRATCH_RE='^(WORKER_BRIEF\.md|CONTINUE\.md|BRIEF\.md)$'

removed=0
skipped=0
needs_review=0
removed_list=()
skipped_list=()
review_list=()

# Refresh the remote tracking ref once up front. Doing this per-worktree
# below would be an N-fetch penalty for data that doesn't change between
# worktrees. Track whether it actually succeeded (offline is fine, but if
# it fails we can't trust a possibly-stale origin/main to prove "merged"
# after a remote history rewrite).
#
# The default branch comes from origin/HEAD, not an assumed `main`.
DEFBR="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
DEFBR="${DEFBR#origin/}"
if [ -z "$DEFBR" ]; then
  for c in main master; do
    if git rev-parse --verify --quiet "refs/remotes/origin/$c" >/dev/null; then DEFBR="$c"; break; fi
  done
fi
DEFBR="${DEFBR:-main}"
FETCH_OK=1
git fetch origin "$DEFBR" --quiet 2>/dev/null || FETCH_OK=0

# `gh` guesses the repo from its own default, which can differ from origin (it
# resolved dishdirectory to directory-template on 2026-10-21). Pass --repo always.
SLUG=""
ORIGIN_URL="$(git config --get remote.origin.url 2>/dev/null || true)"
case "$ORIGIN_URL" in
  https://github.com/*|git@github.com:*)
    SLUG="${ORIGIN_URL#https://github.com/}"; SLUG="${SLUG#git@github.com:}"; SLUG="${SLUG%.git}" ;;
esac

# Directories that hold a running process. Removing one under a live agent breaks it.
command -v lsof >/dev/null || { echo "error: lsof not found; cannot check for live processes" >&2; exit 1; }
LIVE_CWDS="$(lsof -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)"

# Ignored paths that rebuild on demand. Any other ignored file (.env.local,
# .dev.vars, keys) may be the only copy, so it sends the worktree to needs-review.
REGEN_RE='(^|/)(node_modules|\.next|\.open-next|\.turbo|\.wrangler|\.cache|\.parcel-cache|\.pytest_cache|\.venv|__pycache__|dist|build|target|coverage|\.DS_Store)/?$'

# --- Enumerate linked worktrees via porcelain output ---
# Blocks look like: "worktree <path>", "branch refs/heads/<name>", ...
current_path=""
current_branch=""
process_worktree() {
  [ -n "$current_path" ] || return 0
  # `line` must be local: the status loop below reads into it, and the caller's
  # loop reuses the same name, so a global would blank the next worktree's path
  # and skip it without a trace.
  local line wt="$current_path" br="$current_branch"
  current_path=""; current_branch=""

  # Skip the main worktree itself.
  if [ "$wt" = "$MAIN_TOP" ]; then
    return 0
  fi

  # SAFETY: verify this is a genuine LINKED worktree before touching it.
  # A linked worktree's gitdir is exactly <common-gitdir>/worktrees/<name>.
  # A main clone's gitdir is <dir>/.git — never delete those. Anchor on
  # COMMON_GITDIR (not a bare "*/worktrees/*" substring test) so a stale
  # worktree slot that got manually replaced by an unrelated clone isn't
  # mistaken for a real linked worktree just because its own path happens
  # to contain a "worktrees" directory component (e.g. /srv/worktrees/foo).
  local gitdir
  if ! gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"; then
    skipped_list+=("$wt (not a git worktree)")
    skipped=$((skipped + 1))
    return 0
  fi
  case "$gitdir" in
    "$COMMON_GITDIR/worktrees/"*) ;; # genuine linked worktree, proceed
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
  # Prefer origin/main; fall back to local main/master when no remote
  # exists. But if origin *is* configured, the earlier fetch failed, and
  # origin/main still doesn't resolve, don't silently trust local main: it
  # could be an arbitrarily stale snapshot from before that remote was
  # ever fetched — the same "looks merged against stale history" trap
  # this script already guards against below via FETCH_OK.
  local intobranch="origin/$DEFBR"
  if ! git rev-parse --verify --quiet "$intobranch" >/dev/null; then
    if [ "$FETCH_OK" -eq 0 ] && git remote get-url origin >/dev/null 2>&1; then
      review_list+=("$wt ($short cannot verify merge: origin is configured but $intobranch is unresolvable and the fetch failed; verify manually)")
      needs_review=$((needs_review + 1))
      return 0
    elif git rev-parse --verify --quiet "refs/heads/$DEFBR" >/dev/null; then
      intobranch="$DEFBR"
    fi
  fi
  local tip
  tip="$(git -C "$wt" rev-parse HEAD)"
  if git merge-base --is-ancestor "$tip" "$intobranch" 2>/dev/null; then
    merged=1
  elif [ -n "$SLUG" ] && command -v gh >/dev/null 2>&1; then
    # Squash and rebase merges leave the tip off the default branch. Accept a
    # MERGED PR only when its head SHA is the current tip. A closed PR is no
    # evidence, and commits pushed after the merge are unmerged work.
    if gh pr list --repo "$SLUG" --head "$short" --state merged \
         --json headRefOid --jq '.[].headRefOid' 2>/dev/null | grep -qx "$tip"; then
      merged=1
    fi
  fi
  if [ "$merged" -eq 0 ]; then
    skipped_list+=("$wt ($short not merged)")
    skipped=$((skipped + 1))
    return 0
  fi
  # A "merged" verdict from a stale origin/main (fetch failed above, e.g.
  # offline) can't be trusted after a remote history rewrite: the branch
  # may look merged against the old cached ref while current main no
  # longer contains it. Route to needs-review instead of removing.
  if [ "$intobranch" = "origin/$DEFBR" ] && [ "$FETCH_OK" -eq 0 ]; then
    review_list+=("$wt ($short merged per stale origin/main; fetch failed, verify manually)")
    needs_review=$((needs_review + 1))
    return 0
  fi

  # --- Live process check: an agent may be working here right now ---
  local wt_real
  wt_real="$(cd "$wt" && pwd -P)"
  if printf '%s\n' "$LIVE_CWDS" | awk -v p="$wt_real" '$0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }'; then
    skipped_list+=("$wt ($short live process in directory)")
    skipped=$((skipped + 1))
    return 0
  fi

  # --- Cleanliness check ---
  # --ignored: plain status hides ignored files such as .env.local, and
  # `git worktree remove` deletes them with the directory.
  local status real_dirty=0 ignored_real=0
  status="$(git -C "$wt" status --porcelain --ignored 2>/dev/null || echo "__ERROR__")"
  if [ "$status" = "__ERROR__" ]; then
    review_list+=("$wt ($short status unreadable)")
    needs_review=$((needs_review + 1))
    return 0
  fi
  local scratch_paths=()
  if [ -n "$status" ]; then
    # Any changed path outside the scratch set counts as real. Match the
    # full repo-relative path (not basename) so a real file that merely
    # shares a name with a scratch file, e.g. docs/BRIEF.md, isn't
    # mistaken for the harmless root-level scratch note.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # Porcelain v1: XY + space + path (handle renames "old -> new").
      local f="${line:3}"
      # Ignored entries ("!! path"): regenerable ones are fine, any other is
      # a file git will not restore, so keep the worktree for review.
      if [ "${line:0:2}" = "!!" ]; then
        printf '%s' "$f" | grep -Eq "$REGEN_RE" || ignored_real=1
        continue
      fi
      # A rename is never scratch-only: checking just the destination name
      # would let e.g. "important.txt -> BRIEF.md" pass as harmless, and
      # --apply's cleanup below (reset + checkout/rm on the new path alone)
      # can then delete the only copy of the renamed content. Treat any
      # rename as a real change regardless of what either side is named.
      case "$f" in
        *" -> "*)
          real_dirty=1
          break
          ;;
      esac
      if ! printf '%s' "$f" | grep -Eq "$SCRATCH_RE"; then
        real_dirty=1
        break
      fi
      scratch_paths+=("$f")
    done <<< "$status"
  fi
  if [ "$real_dirty" -eq 1 ]; then
    # Real changes: never delete. Report for manual salvage
    # (commit to a salvage branch and push).
    review_list+=("$wt ($short merged but has real changes)")
    needs_review=$((needs_review + 1))
    return 0
  fi
  if [ "$ignored_real" -eq 1 ]; then
    review_list+=("$wt ($short merged but holds ignored files that would be lost, e.g. .env.local)")
    needs_review=$((needs_review + 1))
    return 0
  fi

  # --- Safe to remove (or dry-run report) ---
  if [ "$APPLY" -eq 1 ]; then
    # Clear the verified scratch-only files first: `git worktree remove`
    # refuses any dirty worktree, scratch files included, and we deliberately
    # don't pass --force, since --force also bypasses `git worktree lock` —
    # a locked worktree must still block removal. Unstage before restoring:
    # `checkout -- <path>` only ever restores the worktree from the index,
    # so a *staged* scratch-file change (index differs from HEAD, working
    # tree already matches index) would otherwise survive untouched and
    # `git worktree remove` would still see it as dirty.
    for f in ${scratch_paths[@]+"${scratch_paths[@]}"}; do
      git -C "$wt" reset -q -- "$f" 2>/dev/null || true
      git -C "$wt" checkout -- "$f" 2>/dev/null || rm -f -- "$wt/$f"
    done
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
done <<< "$WT_PORCELAIN"
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
