#!/usr/bin/env python3
"""Generate repo-prefixes.json: unique 2-4 char prefix per pooriaarab repo.

Run:  python3 build-repo-prefixes.py > repo-prefixes.json
"""

import json
from pathlib import Path
import re
import subprocess
import sys

# ── helpers ──────────────────────────────────────────────────────────────

def gh_list():
    """Fetch all pooriaarab repos via gh CLI."""
    r = subprocess.run(
        ["gh", "repo", "list", "pooriaarab", "--limit", "300",
         "--json", "name,diskUsage,isArchived,isFork"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


# Small dictionary of known English words for word-boundary detection
KNOWN_WORDS = {
    # vibe* suffixes
    "ads", "agent", "brand", "build", "care", "code", "context", "create",
    "core", "daily", "dating", "debug", "donate", "family", "gen", "health",
    "home", "hooks", "host", "kids", "learn", "live", "memory", "money",
    "movie", "music", "network", "news", "notifications", "publish", "qa",
    "radio", "replay", "review", "score", "share", "stream", "study", "teens",
    "translate", "voice",
    # other common words
    "slack", "bot", "gmail", "fox", "cade", "private", "conductor",
    "playground", "default", "branch", "alert", "article", "video",
    "master", "template", "cloudflare", "netlify", "firebase",
    "wordpress", "meta", "description", "generator", "alternative", "text",
    "featured", "image", "notion", "backup", "n8n", "telegram",
    "near", "nomination", "onchain", "nft", "static", "svg",
    "crypto", "foodies", "locowalk", "business", "pagely", "redirect",
    "penguin", "rewards", "users", "richedu", "website", "beehouse",
    "x", "to",
}

def split_camel_lower(s: str) -> list[str]:
    """Split a lowercase concatenated string into known words (greedy)."""
    words = []
    i = 0
    while i < len(s):
        # Greedy: try to match longest known word from this position
        best = None
        for wl in range(min(14, len(s) - i), 0, -1):
            part = s[i : i + wl]
            if part in KNOWN_WORDS or part in KNOWN_WORDS:
                best = part
                break
        if best is None:
            # Fallback: treat single char as its own "word"
            best = s[i]
        words.append(best)
        i += len(best)
    return words


def derive_prefix(name: str) -> str:
    """Derive a 2-4 lowercase prefix for a repo name.

    Rules applied in order:
    1. Hyphen / underscore / dot separated → first letter of each part (max 4)
    2. Names that are obviously an initialism → human-picked (rts for replytosocial)
    3. Single word → first 3 letters, then resolve collisions later
    """
    name_lower = name.lower()

    # ── Known initialisms (hand-picked, human-readable beats mechanical) ──
    overrides = {
        "replytosocial": "rts",        # reply to social
    }
    if name_lower in overrides:
        return overrides[name_lower]

    # ── Separated names ──
    # Split on every separator in one pass so a mixed name like "foo-bar_baz"
    # yields one part per word (f, b, b), not just per the first separator found.
    if re.search(r"[-_.]", name_lower):
        parts = [p for p in re.split(r"[-_.]+", name_lower) if p]
        if parts:
            prefix = "".join(p[0] for p in parts[:4])
            # Must be at least 2 chars
            if len(prefix) < 2 and len(parts) > 1:
                # Take more from second part
                prefix = prefix[:1] + parts[1][:3]
            return prefix[:4]

    # ── Single-word name ──
    # First: try word-boundary detection for obvious compounds like vibecodereview
    # Check if it's a vibe* repo (the most common compound pattern)
    if name_lower.startswith("vibe") and name_lower != "vibe":
        suffix = name_lower[4:]  # strip "vibe"
        suffix_words = split_camel_lower(suffix)
        # v + first letter of each suffix word
        return ("v" + "".join(w[0] for w in suffix_words))[:4]

    # Default: first 3 letters
    prefix = name_lower[:3]
    return prefix[:4]


def resolve_collisions(prefixes: dict[str, str], fixed: set[str] = frozenset()) -> dict[str, str]:
    """Resolve prefix collisions by extending shorter prefixes.

    `fixed` names are already-registered prefixes and must never be
    reassigned. For each collision group, only the non-fixed (fresh)
    names extend, left-to-right, until unique, up to 4 chars max.
    """
    # Build reverse map: prefix → [repo names]
    by_prefix: dict[str, list[str]] = {}
    for repo, pref in prefixes.items():
        by_prefix.setdefault(pref, []).append(repo)

    result = dict(prefixes)

    for pref, repos in by_prefix.items():
        if len(repos) == 1:
            continue

        has_fixed = any(repo in fixed for repo in repos)
        # Sort the fresh repos alphabetically for deterministic extension.
        # Fixed (registered) repos never move, so they aren't in this list.
        fresh_sorted = sorted(repo for repo in repos if repo not in fixed)

        # A fixed repo already holds `pref`, so every fresh repo in this
        # group must move. Otherwise the first fresh repo (alphabetically)
        # keeps `pref`, matching the old all-fresh behavior.
        taken: set[str] = {pref} if has_fixed else set()

        for repo in fresh_sorted:
            current = result[repo]
            while current in taken:
                # Try extending by one more character. Strip separators so a
                # hyphen/underscore/dot never lands inside the prefix (it would
                # fail the isalpha check below and abort the whole run), and
                # cap at 4 -- the max length a prefix is allowed to be.
                name = re.sub(r"[-_.]", "", repo.lower())
                for pos in range(len(current) + 1, min(len(name), 4) + 1):
                    candidate = name[:pos]
                    # Check every prefix in play, not just this collision group.
                    # A group-local check lets an extended prefix land on one an
                    # unrelated repo already holds; main() then rejects the whole
                    # run for a name the generator could have resolved itself.
                    others = {result[r] for r in result if r != repo}
                    if candidate not in taken and candidate not in others:
                        current = candidate
                        break
                else:
                    # Last resort: couldn't extend further
                    break
            result[repo] = current
            taken.add(current)

    return result


# ── Main ────────────────────────────────────────────────────────────────

def main():
    repos = gh_list()

    # Filter: non-archived, non-fork, diskUsage >= 10 (≈ 10KB min)
    eligible = [
        r for r in repos
        if not r["isArchived"] and not r["isFork"] and r["diskUsage"] >= 10
    ]

    # A prefix is permanent. Once a repo has one, branch names, PR titles and
    # merged commits carry it, so regenerating must never reassign it. Load what
    # is already registered and derive only for repos that have none.
    registry_path = Path(__file__).with_name("repo-prefixes.json")
    existing: dict[str, str] = {}
    if registry_path.exists():
        existing = json.loads(registry_path.read_text())

    # Keep every already-registered entry, even for a repo that fell out of
    # `eligible` (archived, renamed, deleted). Dropping it here would free its
    # prefix for reassignment, breaking the permanence guarantee above.
    prefixes: dict[str, str] = dict(existing)
    fresh: dict[str, str] = {}
    for repo in sorted(eligible, key=lambda r: r["name"]):
        name = repo["name"]
        if name not in existing:
            fresh[name] = derive_prefix(name)

    # Resolve collisions among the new names only, against everything already held.
    if fresh:
        merged = dict(prefixes)
        fixed = set(prefixes.keys())
        merged.update(fresh)
        resolved = resolve_collisions(merged, fixed=fixed)
        for name in fresh:
            prefixes[name] = resolved[name]

    # Validate
    values = list(prefixes.values())
    if len(values) != len(set(values)):
        dupes = {v for v in values if values.count(v) > 1}
        print(f"ERROR: duplicate prefixes detected: {dupes}", file=sys.stderr)
        sys.exit(1)

    for name, pref in prefixes.items():
        if not (2 <= len(pref) <= 4) or not pref.islower() or not pref.isalpha():
            print(f"ERROR: invalid prefix '{pref}' for repo '{name}'", file=sys.stderr)
            sys.exit(1)

    # Output sorted JSON
    sorted_map = dict(sorted(prefixes.items()))
    json.dump(sorted_map, sys.stdout, indent=2, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()