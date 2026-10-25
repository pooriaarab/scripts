# Submit a site to the GitHub lists

`../specs/github-lists.jsonl` holds one record per awesome list, API list, MCP list or catalog on GitHub.
Each record says which repo takes the entry, which files to edit, what an entry looks like, how to title the PR,
which rules apply, and what happened to the fleet's own entries. Read it with `../specs/lookup.py`:

```sh
python3 ../specs/lookup.py --method github-pr -q          # lists that take a PR
python3 ../specs/lookup.py awesome-openapi                # one record
```

## Keys that matter here

| Key | Meaning |
|---|---|
| `upstream`, `base` | The repo and its default branch. |
| `files`, `entry_example` | The files a change edits, and one real entry as it was added. Copy its shape. |
| `title_example` | The PR or issue title style. |
| `one_entry_per_pr` | `true` means one link per PR. File one PR per site, and no more than 3 per repo. |
| `ai_disclosure` | `true` means the PR body says AI helped. Some lists ask for it. |
| `checks` | What the repo's own validation said when the patch was made. Run the repo's check again. |
| `gate`, `gate_note` | `none` means a free filing works. `human` carries the reason it did not. |
| `outcome` | The PRs and issues the fleet filed, with their state when the record was written. |

## Steps for a new site

1. Write the site's facts in one JSON file: name, url, tagline, short and long description, tags, API and MCP links.
2. For each list with `gate: none`, check the fit. Skip a list whose scope does not cover the site. Never stretch a description.
3. Clone the repo, read its `CONTRIBUTING` and the last 10 merged PRs, then add the entry in the shape of `entry_example`.
4. Save `change.patch` (`git diff`) and `pr.json` in a folder. `worker-brief.md` states the exact files and keys.
5. Read the patch and the PR text. Then run `./file-pr.sh <absolute folder>`. It forks, applies the patch, pushes and opens the PR.
6. Record the link in the submissions ledger.

`worker-brief.md` is the brief the fleet gave to a worker agent on a Box. The worker prepares patches and uses no
credentials. A person files them.

## Lessons from the first run (2026-10-24)

- A maintainer who reads every PR can decline within minutes. Three lists by one maintainer declined 7 of 7
  entries. They wanted proof of data freshness and independent adoption. Wait for adoption before you file there again.
- One list bans PRs from agents in its `CONTRIBUTING`. Do not file there. Read that file first.
- A fork name can clash with a fork you already own. The fork API returns the existing fork, so use its answer.
