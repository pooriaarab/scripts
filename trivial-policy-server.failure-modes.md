# trivial-policy-server failure modes

`trivial-policy-server.py` is a fake OpenAI-compatible endpoint. It answers every chat request with one fixed trivial policy, chosen by the model id (`trivial-empty`, `trivial-yes`, `trivial-ok`, `trivial-refuse`, `trivial-echo`, `trivial-firsttool`, `trivial-random`, `trivial-nulljson`). It lets a benchmark package run its real code path with no model, no key and no cost.

The tests in `trivial-policy-server.test.sh` cover each row marked "tested". No network beyond localhost.

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | The model id is not `trivial-<policy>` or the policy is unknown. | Answer 400 and name the allowed policies. Never invent an answer. | yes |
| 2 | The body is not JSON. | Answer 400. | yes |
| 3 | The route is not chat completions or models. | Answer 404. | yes |
| 4 | `firsttool` is asked when the request offers no tool. | Answer with plain text `done`, never a tool call to nothing. | yes |
| 5 | `firsttool` is asked when tools are offered. | Answer with one call to the first tool, empty arguments, `finish_reason` `tool_calls`. | yes |
| 6 | `echo` meets a message whose content is a list of parts. | Join the text parts. Never crash. | yes |
| 7 | `random` is called twice with the same text. | The word depends on the request count, so a full run is repeatable. | yes |
| 8 | The server is used as evidence about a real model. | It is not one. Reports name the model `trivial-*`. The paper calls these policies, not models. | no, a human rule |
