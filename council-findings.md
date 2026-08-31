# 🧑‍⚖️ LLM Council findings

Independent per-lens reviews from council models. Treat as co-reviewer input: de-dupe, verify each claim against the code, discard false positives, and only fix confidently-real issues.

## GPT-5.6 (Codex) — correctness lens

pr-standards.mjs:383 — A fence indented relative to a list container, such as `- item` followed by a four-space-indented fence containing two-space-indented attachment URLs, is rendered as fenced code by GitHub but missed by the three-space ceiling, so hidden URLs count as proof -> track list-container indentation and apply the three-space fence allowance relative to that container.

pr-standards.mjs:493 — Two malformed placeholder URLs such as `https://github.com/user-attachments/assets/<before>` and `/assets/<after>` are counted as distinct attachments because the asset matcher accepts angle brackets -> restrict the captured asset ID to GitHub’s valid identifier syntax.

## Gemini 3 Pro — performance lens

_timed out_

## Kimi K3 — security lens

_moonshot HTTP 429, openrouter: timed out_

## Grok 4.5 — maintainability lens

_timed out_

## GPT-5.6 (scope) — scope lens

No findings.
