# free-only-proxy failure modes

`free-only-proxy.py` sits between a benchmark package and OpenRouter. It forwards chat requests for models whose id ends in `:free`, spaces them out, counts them per day, and refuses everything else. Its job is to make a paid call impossible, not just unlikely.

The tests in `free-only-proxy.test.sh` cover each row marked "tested". They use a fake upstream on localhost. No network, no key.

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | The request names a model that does not end in `:free`. | Answer 403 `paid model blocked`. Never contact the upstream. | yes |
| 2 | The body carries a `models` fallback list with any paid id. | Answer 403. A fallback is a route to a paid model. | yes |
| 3 | The body has no model at all. | Answer 400. Never guess. | yes |
| 4 | A `:free` model answers with a nonzero `usage.cost`. | Write the `STOP` file, answer 503 to this and every later request, and say so on stderr. The run must not go on spending. | yes |
| 5 | The daily request count is reached. | Answer 429 with `Retry-After` and write `DAILY_LIMIT`. Counting survives a restart (state file, UTC date). | yes |
| 6 | The upstream answers 429 or 5xx. | Retry up to three times with growing waits, honoring `Retry-After`. After that pass the error through. | yes |
| 7 | Two workers call at once. | Upstream calls are serialized and spaced by the minimum interval. | yes |
| 8 | A key or a prompt is logged. | The log holds time, model id, status and token counts only. The test greps for the test key and for a prompt marker. | yes |
| 9 | The key is missing. | Exit 2 at start. | yes |
| 10 | A route other than chat completions or models. | Answer 404. | yes |
| 11 | OpenRouter swaps or drops a free model. | The upstream error is passed through. The runner records the failed cell. The paper says the study is a dated snapshot. | no, an upstream fact |
