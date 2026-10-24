# Board specs

One record per directory board that the fleet has met. A record says where to
submit, how to sign in, which steps and fields the form has, what the board
shows after a good submit, and which gate stops a free filing. A later run
reads the record instead of exploring the board again.

| File | Holds |
|---|---|
| `boards.jsonl` | Boards where the structure was seen: `verified` is `filed` or `static-html`. |
| `blocked.jsonl` | Boards where only the gate is known: `verified` is `registry-only`. Do not retry these without a reason. |
| `lookup.py` | Find a board by name, gate, method or verified level. |

Each file has one JSON object per line, sorted by `slug`.

## Read a record

```sh
python3 lookup.py fridayhunt
python3 lookup.py --method form-anon --free -q
python3 lookup.py --gate badge-required -q
```

## Keys

| Key | Meaning |
|---|---|
| `target` | The exact name in `submissions/ledger.csv`. |
| `slug` | Lowercase letters, digits and `-`. |
| `url`, `submit_url` | Board home and submit page. |
| `method` | `form-anon`, `form-account`, `github-pr`, `email`, `api`, `oauth-google`, `oauth-github` or `crawl`. A `github-pr` route may be an issue form. |
| `login` | How sign-in works. It never holds a password. |
| `steps`, `fields` | Step order and field labels as shown on the board. |
| `confirmation` | The text or URL the board shows after a good submit. |
| `limits`, `gate`, `gate_note`, `free_path` | Rate limits, review delay, and what blocks a free filing. |
| `link_rel` | `dofollow`, `nofollow` or `unknown`. |
| `driver` | The module in `../drivers/`, or `null`. |
| `verified`, `verified_on`, `evidence` | How sure the record is, when, and where it came from. |

`verified` has three levels. `filed` means a person or agent filed on the live
board and saw the confirmation. `static-html` means the form was read from the
public page without filing. `registry-only` means no page was opened.

A record can go stale when a board changes its form. Run `--dry-run` on one site
before a batch, and fix the record if the form moved.

A record never holds a secret, a cookie or a password. It names a setting, for
example `DIRSUB_MAKER_NAME`, and the driver reads it from the environment.
