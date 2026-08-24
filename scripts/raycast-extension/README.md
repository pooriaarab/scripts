# raycast-extension — build, run, and submit a Raycast extension

A Raycast extension is TypeScript + React on **`@raycast/api`**; `package.json` is the
manifest. Unlike browser/Canva stores there is no portal upload — **submission is a PR
into the `raycast/extensions` monorepo**. This is the playbook: the command sequence from
`integrations/raycast-extension/` to merged-PR, plus the traps that each cost a
round-trip. The concept-level skill is `raycast-extension` in the sibling skills repo.

## Flow

```bash
cd integrations/raycast-extension   # isolated package: src/, assets/, package.json (manifest)
npm install
npm run dev                         # ray develop — hot-reload inside Raycast
# ... build commands: src/<command-name>.tsx default-exporting List/Form/Detail ...
npm run build                       # ray build — type-check + bundle; must be clean
npm run lint                        # ray lint (@raycast/eslint-config)
```

The manifest, in `package.json` (schema: `https://www.raycast.com/schemas/extension.json`):

- `commands[]` — one entry per command; **`name` must equal the src/ filename**
  (`"name": "new-post"` ↔ `src/new-post.tsx`). `mode`: `view` (React UI) | `no-view`
  (headless async fn) | `menu-bar`.
- `preferences[]` — user config. API key: `{ "name": "apiKey", "type": "password",
  "required": true, ... }`; read it in code with `getPreferenceValues<Preferences>()`.
- `author` — your **registered Raycast username** (lint/CI reject anything else).
- `categories` — from the fixed allowed list only. `icon` — a 512×512 PNG in `assets/`.
- `raycast-env.d.ts` is generated from this file — never hand-edit; rerun `ray develop`
  to regenerate.

## Submit to the Raycast Store

1. Fork `github.com/raycast/extensions`; add the package as `extensions/<extension-name>/`.
2. Confirm `author` is your registered Raycast username.
3. `npm install && npm run build && npm run lint` inside the monorepo layout (CI reruns them).
4. Ensure the extension dir has its own README telling a fresh reviewer how to get an API
   key (self-serve signup or clear steps — they have no account of yours).
5. Open the PR against `raycast/extensions`. Bot checks manifest hygiene; a human review
   follows (days). Push fixes to the same PR. Updates later = new PRs against the same dir.
6. Screenshots go in a `metadata/` folder in the extension dir — PNG, `2000×1250`, named
   `screenshot-1.png` … (max 6, at least one required). Shoot them with Raycast's built-in
   **Window Capture** so the dev-mode icon is stripped.
7. `npx @raycast/api@latest publish` (run from the extension dir) authenticates with GitHub,
   forks `raycast/extensions`, copies the extension in, and opens the PR — still ends in a
   human PR review. Build + lint must be clean first; CI reruns them. Updates later = new PRs
   against the same dir.

## Traps (each = one round-trip)

- **Command `name` ≠ filename** — the command silently doesn't exist. The manifest, not
  the file tree, defines what ships.
- **`author` not a registered username** — lint/store CI reject; fix before opening the PR.
- **Hardcoded API key** — leaks into a public monorepo and bounces review. Use a
  `password` preference + `getPreferenceValues<Preferences>()`. Never commit `.env`/keys.
- **Editing `raycast-env.d.ts`** — it's generated; stale `Preferences` types mean the
  manifest changed and you didn't rerun `ray develop`.
- **No progress UI** — long API calls need `showToast` Animated → Success/Failure with the
  real error message; silent failures are review-bait.
- **`npm publish`** — the store is not npm; keep the `prepublishOnly` guard that blocks it.
- **Wrong `mode`** — `no-view` commands can't render; `view` commands must default-export
  a component.

## Files

`example.ts` (next to this README) — the smallest real wiring: a Form command that reads
the API key from preferences, calls your API, and reports via Toast. Copy it as a
starting point; add a matching entry to `commands[]` in `package.json`.
