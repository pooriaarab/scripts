# claude-connector

Submit a hosted MCP server to the Claude Connectors Directory
(`claude.ai/directory/manage/new/connector`) by driving the 10-step wizard in a
logged-in Chrome.

## Run

```sh
node submit.mjs sites/private-repo-f838.json           # run the wizard, submit for review
node submit.mjs sites/private-repo-f838.json --status  # read its row on the submissions page
node submit.mjs sites/private-repo-f838.json --publish # "Ready to publish" -> Published
node submit.mjs sites/private-repo-f838.json --dry-run # print, don't touch
```

Prereqs: `browser-personal` Chrome running with CDP 9334 (`open -na` so it
survives between calls — `nohup` dies with the shell), logged in to claude.ai
with a paid-plan account that owns a company on the portal.

## The 10 steps and their traps

| Step | What it wants | Trap |
| --- | --- | --- |
| 1 Connection | Server URL → "Connect and authorize" | The probe POSTs `initialize` with the **client's** `mcp-protocol-version` header. If the server 400s unknown headers *on initialize*, the wizard reads it as auth-gated and shows "0 Tools". The header binds post-initialize requests only — negotiate from `params.protocolVersion`. (Fixed fleet-wide: private-repo-297b #275.) Wait for "N Tools" before Next. |
| 2 Tools | Read-only review | "Missing title annotation" is a suggestion, not a blocker. |
| 3 Listing | name, slug (PERMANENT), one-liner, description, categories, docs, support, privacy | React inputs need native setter + `input` event. Categories: focus the `input[role=combobox]`, click the option by exact `textContent`. Docs = the site's `/developers` page. Support accepts an email. |
| 4 Use cases | 1-3 (use_case, prompt) pairs + prerequisites + read/write radio | Radio inputs are `input[type=radio]` with values `read_only`/`write_only`/`read_write` — `.click()` works on the input itself. |
| 5 Company | company name, website, contact name/email (prefilled), role | Only website + role are empty by default. |
| 6 Authentication | Always / When asked / None | Options are styled spans, not inputs: click the leaf `span`'s closest `span[class*=group]`. Verify `no_auth` checked before Next. |
| 7 Data handling | API ownership, health data, sponsored content | Same span-radio trick; there are TWO `No` spans — click both. |
| 8 Test & launch | test instructions + self-tested checkbox | Public/no-auth servers: say so, give the URL and one example call. |
| 9 Compliance | 7 required checkboxes | Check every visible checkbox. |
| 10 Review | summary + Submit for review | Ends with "Server submitted for review". |

## Hard-won mechanics

- **Every eval must be self-contained** — `const` persists across evals in the
  same tab; wrap helpers in IIFEs.
- **"Draft saved in this tab"** — the wizard persists state; the script is safe
  to re-run, it resumes at the current step.
- **Slug is permanent** — choose it once (we use `<name>-fyi` / `private-repo-ba8a`).
- **Bind a dedicated tab, then re-check `location.href`** — a shared tab can be
  navigated away mid-run by the user or another agent. The script opens the
  wizard itself; if the eval lands on a foreign page the step detector returns
  "unknown" and the script exits nonzero rather than print a false DONE.
- After submit, track at `claude.ai/directory/manage` → Submissions. Review
  takes "a few weeks"; the contact email gets the verdict. States seen today:
  `In review` → `Ready to publish` → (`Publish` → confirm) → `Published (done)`.

## Publishing (post-approval)

- `claude.ai/directory/manage/<slug>` has a **Publish** button once approved.
- The confirmation is a `position:fixed` `[role=alertdialog]` — `offsetParent`
  is null for fixed elements, so visibility filters like
  `.filter(e => e.offsetParent)` report "no dialog" while it is on screen.
  Detect it by role + text (`"Publish this server"`), not visibility.
- The dialog's **Publish** ignores a bare `.click()`. Dispatch the full
  sequence (`pointerdown`, `mousedown`, `pointerup`, `mouseup`, `click`)
  with coordinates from `getBoundingClientRect()`.
- `--publish` does all of this and fails nonzero unless the detail page then
  reads `Published (done)`.
