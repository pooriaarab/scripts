# zapier — build, push, and publish an integration

Zapier is **CLI-first**, so unlike Make there is no `publish-app.py` — the
`zapier` CLI (`zapier-platform-cli`) is the tool. This file is the playbook: the
exact command sequence to take an integration from `integrations/<app>/` to
submitted-for-review, plus the traps that each cost a validate/promote round-trip.

## Flow

```bash
cd integrations/<app>            # the integration source (index.js, auth, creates/, triggers/, searches/)
npm i -g zapier-platform-cli     # or: it's already installed; `zapier --version`
zapier login                     # once per machine (interactive)

zapier validate                  # 0 errors required before anything else
zapier register "<Title>" \      # creates the app + writes .zapierapprc (gitignore it)
  --desc "<=140 chars>" \
  --url "https://<homepage>" \
  --audience global \            # global = public directory; private = link-only
  --role user \
  --category social-marketing \
  --yes
zapier push                      # bundles + uploads the current code as a version
zapier promote <version> --yes   # SUBMIT FOR REVIEW (new public app) → Beta
```

`zapier test` runs the integration's `test` script against real auth — needs a
real API key in `.env` (`zapier env` / bundle authData), so it's the one step
that wants a throwaway PROD account.

## Traps (each one bounced a run)

- **Core version must be EXACT, matching the CLI major.** `package.json`
  `zapier-platform-core: "^16.0.1"` fails validate with *"must depend on an exact
  version."* CLI 17.x → pin `"17.8.0"`. A `^`/`~` range never passes.
- **A dynamic dropdown must reference a TRIGGER, not a search (D005).** A field
  with `dynamic: "list_x.id.name"` where `list_x` is a *search* fails. Make a
  **hidden trigger** (`display: { hidden: true }`) that returns `{id, name}[]`
  and point the field at `dynamic: "x_dropdown.id.name"`. (Searches back the
  *Find* actions; hidden triggers back the *dropdowns*.)
- **Every search needs ≥1 input field (D009).** An empty `inputFields: []` fails.
  Add at least one (e.g. a `name` "contains" filter) and actually use it.
- **`zapier register` is not fully non-interactive without `-u`.** Omit the
  homepage URL flag and it drops to an interactive prompt; under a pipe that
  readline throws `ERR_USE_AFTER_CLOSE` and aborts. Always pass `--url`. Full
  non-interactive set: title arg + `--desc --url --audience --role --category
  --yes`.
- **There is no `zapier submit`.** `zapier promote <version>` is the
  submit-for-review action for a brand-new public app. It's safe for existing
  users (grandfathers old versions).
- **Promote requires a `CHANGELOG.md`** with a user-facing `## <version>` entry
  in the pushed source, or it errors before submitting. Add it, `zapier push`
  again, then promote. Optional `#<issueId>` / `<trigger|create|search>/<key>`
  tokens in the entry associate the changelog with issues/actions.
- **Promote U001 — Developer ToS gate.** Promote pre-checks (L001–L004) pass but
  fail on `meta.tos_agreement (U001)`: *"You must agree to the latest Developer
  Terms of Service."* This is a legal click a human does once at
  <https://zapier.com/app/developer>; the CLI cannot accept it. After the human
  accepts, re-run `zapier promote`.
- **`.zapierapprc`** links the working dir to the registered app id. It's
  machine/account state — gitignore it (also `.env`, `build/`, `node_modules`).

## The usage gate (Beta → public directory)

Submitting + passing review lands the app in **Beta**. Exiting Beta into the
public App Directory needs **50 active users AND ≥10 published Zap templates** —
OR **a single in-product Zapier embed**, which waives the 50-user rule. So the
fast path off Beta is: embed Zapier in the product + author ~10 useful Zap
templates (they double as the app page's "flows" showcase).

## Keep the connector honest with the live API

The integration calls the product's public REST API by URL. When the API renames
a path (Content Rabbit: `/public/v1/social-sets` → `/public/v1/teams`), every
call site 404s silently. Grep the connector for hard-coded paths whenever the API
changes, and keep auth-field copy (labels, help text) aligned with current
product branding.
