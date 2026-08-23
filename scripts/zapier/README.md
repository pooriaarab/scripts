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

## Wire auth CENTRALLY — the #1 silent bug

**Zapier attaches auth imperatively.** Unlike Make (base `authorization`), n8n
(credential `authenticate` block), or Pipedream (app `_makeRequest`/`_headers()`)
— which all attach auth declaratively/centrally — Zapier applies the connection's
auth to a request **only if you wire it**. The `authentication.test` you write to
verify credentials is a *separate* request; hardcoding the header there does NOT
make your triggers/searches/creates authenticated.

If `index.js` has `beforeRequest: []` empty and your operational files call
`z.request({url, method})` without an `Authorization` header, **every real call
401s** (`"API key missing"`) while the connection test still passes — so *connect
succeeds and nothing else works*, for every user. Wire it once, globally:

```js
// index.js
const addBearerAuth = (request, z, bundle) => {
  if (bundle.authData?.api_key) {
    request.headers = request.headers || {};
    request.headers.Authorization = `Bearer ${bundle.authData.api_key}`;
  }
  return request;
};
module.exports = { /* … */ beforeRequest: [addBearerAuth], /* … */ };
```

**`zapier validate` will NOT catch this — it checks structure, not live calls.**
The only thing that catches it is running a real trigger/action (a Zap editor
"Test", or the review's usage validation). So after `validate` passes, always run
one real operational request before trusting the connector.

**Don't add auth fields the key already scopes.** If the API key is bound to one
tenant server-side, a second "Account/Team/Workspace ID" auth field is dead weight
— it's never sent, only feeds the connection label. Drop it; ask for the key
alone. (Adding it also forces users through an extra field and a reconnect if you
later remove it.)

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

## The submission gate you don't see coming: a live Zap per action

The questionnaire + metadata are necessary but **not sufficient**. Both the CLI
`zapier promote` and the Platform UI "Submit for review" refuse to submit until
**every trigger, search, and create has produced at least one successful task** —
you'll see per-item blockers like *"Needs a successful task but doesn't have a
Zap"*, *"Requires primary key field(s) in latest successful task"*, *"Need to
compare static sample with latest task"* (validation tags T001/T002/T004/T005 +
S002). For a connector with N actions that's ~2–3× N blocking tasks. **A brand-new
app with zero Zaps literally cannot be submitted** — this is the wall, not the
form.

**The cheap way to clear it (verified):** a Zap **editor "Test"** of each step
satisfies its tasks — you do **not** have to publish or turn the Zap on. So:

1. Connect the account **once** (a human pastes the API key into Zapier's connect
   popup — agents are prohibited from typing credentials into fields; but it's
   one-time and every step reuses the connection).
2. Seed data via the product API so triggers have something to poll and write-
   actions have targets (e.g. `POST /posts` to create a record; an id to
   update/delete/schedule).
3. Build a **few** Zaps that *chain many steps* (one Zap = trigger + N action/
   search steps — testing each step clears that item; you don't need one Zap per
   action). Test each step.
4. Watch the blocking count drop as items clear; then submit.

The hard items are triggers that need a real event to poll (e.g. a "new webhook
delivery" trigger needs an actual delivery to exist). Write-actions run for real —
point them at a throwaway tenant with no downstream connections so the side
effects are harmless.

## The other gate (Beta → public directory)

Submitting + passing review lands the app in **Beta**. Exiting Beta into the
public App Directory needs **50 active users AND ≥10 published Zap templates** —
OR **a single in-product Zapier embed**, which waives the 50-user rule. So the
fast path off Beta is: embed Zapier in the product + author ~10 useful Zap
templates (they double as the app page's "flows" showcase).

## The review-request questionnaire (Platform UI → Publishing)

Five collapsible sections gate the Submit button; fill all, then pick the version
+ tick the confirm box:
1. **Integration readiness & API ownership** — "APIs on a domain you don't own?"
   (No, if it's your own API), "production endpoints?" (Yes), "users pay extra?"
   (usually No).
2. **Test account for reviewers** — Zapier **mandates the username be
   `integration-testing@zapier.com`** and requires a password. For a passwordless
   (email-OTP) product: create that exact account in your app (reviewers own that
   inbox, so they receive the login code), put a throwaway password, and in Notes
   explain the OTP login + give the API key + any connection id.
3. **App details** — publicly-launched Yes, homepage, API docs URL, a primary
   color (required), etc.
4. **Contact details** — the contact dropdowns only list **team admins** of the
   integration; add teammates via Manage team first if you need someone specific.
5. **Compliance & platform rules** — company country, sensitive-values No,
   financial No, third-party-APIs (Yes if your product calls other platforms' APIs
   — then a required field to name the API owners + affirm permission), Zapier-
   branding No.

Metadata the promote/submit checks also enforce (fix before submitting): the app
**description must start "`<Name>` is a…"** (M002), **role must be employee/
contractor** not "user" (M003), and a **logo** is required (M004; upload in the
Platform UI, there's no CLI for it).

## Keep the connector honest with the live API

The integration calls the product's public REST API by URL. When the API renames
a path (Content Rabbit: `/public/v1/social-sets` → `/public/v1/teams`), every
call site 404s silently. Grep the connector for hard-coded paths whenever the API
changes, and keep auth-field copy (labels, help text) aligned with current
product branding.
