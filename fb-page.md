# fb-page

`fb-page` creates a Facebook Page, adds it to a Meta business portfolio, and
prints the Page ID. Meta has no API to create a Page, so the script drives a
logged-in Chrome session (`browser-personal`).

The script holds no account name, portfolio ID, site list, or token. Every
value comes from a flag or an environment variable.

## Use

```sh
fb-page create --name "Acme Directory" --category "Website" \
  --portfolio <portfolio-id> --assign-user "<system user name>" --accept-terms \
  --registry ~/path/outside/repo/brand-pages.json --site acme.example
```

The command prints one JSON line: `name`, `page_id`, `portfolio`, `assigned`.

| Command | What it does |
| --- | --- |
| `create` | Creates the Page, then runs `attach`. |
| `attach` | Adds an existing Page, found by name, to the portfolio. |

| Flag or variable | Meaning |
| --- | --- |
| `--portfolio`, `FB_PAGE_PORTFOLIO_ID` | Business portfolio ID. |
| `--assign-user`, `FB_PAGE_SYSTEM_USER` | Display name of the system user to give access. |
| `--permission` | Toggle to enable. Repeat it. Default: Ads and Insights. |
| `--accept-terms` | Ticks the Meta Commercial Terms box for the portfolio. |
| `FB_PAGE_DENY` | Regex. A Page name that matches is refused. Keep it outside the repo. |
| `--registry`, `--site` | Record the brand and Page ID in a JSON file (mode 0600). |

## Rules

- Read the Page ID from the output. The `profile.php?id=` number in a Page URL is
  not the Page ID.
- Keep the registry file outside the repository.
- Use a brand name. Set `FB_PAGE_DENY` to refuse any name that points to a person.
- `--accept-terms` is a legal attestation for the portfolio. The owner decides
  when to pass it. The script never passes it alone.

## Limits

- Chrome must be in front. Meta ignores clicks on a hidden tab. On macOS the
  script brings Chrome forward. Elsewhere it stops and asks you to.
- Meta can flag many new Pages made fast. Create a few at a time.
- The flow depends on Meta's page text. If Meta changes a label, the script
  stops with `Control not found` and the name of the control.

## Test

`python3 fb-page.test.py` runs the script against a fake browser. It checks each
failure and one full run, and that no secret reaches the output.
