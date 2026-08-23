# 🧑‍⚖️ LLM Council findings

Independent per-lens reviews from council models. Treat as co-reviewer input: de-dupe, verify each claim against the code, discard false positives, and only fix confidently-real issues.

## GPT-5.6 (Codex) — correctness lens

scripts/google-workspace-addon/example.gs:38 — Every Workspace add-on Save action fails because CardService supplies inputs under `e.commonEventObject.formInputs`, so `e.formInput.apiKey` dereferences `undefined` -> read and defensively validate `e.commonEventObject.formInputs.apiKey.stringInputs.value[0]`.

scripts/notion-integration/example.ts:43 — A database with more than 100 matching “Ready” rows only processes the first page because `has_more`/`next_cursor` are ignored -> loop queries with `start_cursor` until `has_more` is false.

scripts/wordpress-plugin/example.php:48 — Publishing any public post type such as a Page also sends it to the API because the global `save_post` hook never checks `$post->post_type` -> require the intended post type or register a type-specific hook such as `save_post_post`.

scripts/wordpress-plugin/example.php:87 — A successful API response with invalid JSON or no nonempty `id` is silently accepted without an idempotency marker, so the next save creates a duplicate remote post -> validate the response body and ID, record/surface a contract error, and prevent blind reposting.

## Gemini 3 Pro — performance lens

scripts/wordpress-plugin/example.php:62 — Synchronous `wp_remote_request` inside the `save_post` hook causes blocking I/O that hangs the WordPress admin interface for up to 30 seconds on post save if the external API is slow -> Schedule an async background task (e.g., via `wp_schedule_single_event`) to execute the network request.

## Kimi K3 — security lens

_HTTP 429: {"error":{"message":"Your account org-2a408a06e56445199a5ea8ad0570f41e \u003cak-fc4ygksgxemi11fyqqqi\u003e is suspended due to insufficient balance, please recharge your account or check your plan and billing details","type":"exceeded_current_quota_error"}}_

## Grok 4.5 — maintainability lens

scripts/notion-integration/example.ts:44 — query uses `page_size: 100` and skips rows with Post ID in-process; if Status→Done fails after Post ID is written for 100 rows they stay `Ready`, fill every page, and newer Ready rows never sync → filter on empty Post ID (or paginate all `has_more` pages) and set Post ID+Status in one `pages.update`.
scripts/notion-integration/example.ts:57 — when `postToApi` succeeds and the Post ID `pages.update` throws, catch only writes Error, so the next `syncOnce` has no Post ID and creates a duplicate remote post → record/commit the remote id before treating the row as failed, or retry id write without accepting another POST.
scripts/wordpress-plugin/example.php:86 — a 2xx body without top-level `id` skips `_your_product_post_id`, so every later `save_post` on that published post POSTs another remote resource → require/parse a stable id and set the meta (or a failure marker) before returning; do not leave the “create once” guard unset after a successful HTTP call.
scripts/canva-app/example.ts:5 — example calls `addOnUISdk.app.document.createRenditions` (Adobe Express add-on shape) under a Canva app playbook, so copy-paste against Canva Apps SDK fails at runtime → wire the current Canva export/design API (`@canva/design` or documented equivalent) and matching import.
