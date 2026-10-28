# Use Claude API credits safely

Use this guide for authorized Claude API work in the shared Anthropic workspace.
Claude Code subscription usage and API credits are separate products.

## Get access

Ask the workspace owner for access to the approved Anthropic workspace. Use an
individual, workspace-scoped key or the approved credentials proxy. Do not share
one person's API key with a team.

Check the Claude Console for the workspace, available credits, and grant expiry
before starting a large job. Credit amounts and expiry dates can change. Do not
assume that a previous screenshot or monthly credit limit shows the balance now.

Boat users can check the proxy with `boat ai proxy`. Use it only when it reports
that the proxy is available. If it fails, stop and ask the workspace owner for
an approved access path. Never copy a real key into a Boat box to bypass a proxy
failure.

## Protect data and keys

- Use synthetic or public data only. Never send personal, customer, health,
  payment, or login data.
- Do not send secrets or material the data owner has not approved for this workspace.
- Keep API keys in an approved local secret store. Do not put keys in source,
  prompts, command arguments, shell history, logs, issue comments, or pull
  requests.
- Do not ask another person to paste a key into chat. Request individual access
  from the workspace owner.
- Save results outside the repository until a person reviews them. Remove
  request and response files after the review unless the project needs them.

For this workstation, use the approved secret loader for the local
`ANTHROPIC_API_KEY` and `ANTHROPIC_WORKSPACE_ID` variables. Do not copy the local
secret file into a repository or sandbox.

## Choose a request method

Use a direct Messages API request for interactive work or a small number of
requests. Use the official client SDK where possible. It reads the API key from
`ANTHROPIC_API_KEY`. Add the `anthropic-workspace-id` header when the key is not
scoped to one workspace. Keep `max_tokens` close to the output you need.

Set `ANTHROPIC_MODEL` to an active model approved for the workspace. Check its
current price in the Console before you run work. This synthetic check returns
token counts and does not print the API response:

```python
import os
import anthropic

client = anthropic.Anthropic(
    default_headers={
        "anthropic-workspace-id": os.environ["ANTHROPIC_WORKSPACE_ID"],
    }
)
message = client.messages.create(
    model=os.environ["ANTHROPIC_MODEL"],
    max_tokens=32,
    messages=[{"role": "user", "content": "Reply with: API check passed."}],
)
print(f"input={message.usage.input_tokens} output={message.usage.output_tokens}")
```

Use the Message Batches API for independent work that can finish asynchronously.
Anthropic charges Batch input and output tokens at half of standard API prices.
Check current model prices before you submit. Batch work can take time, so do
not use it for interactive tasks.

Test one request with the Messages API first. Then create the batch with a
unique `custom_id` and the same `params` used by the Messages API. Check its
status, then review every result type. A batch can expire after 24 hours. Its
results are available for 29 days. Batch requests can also go slightly over a
workspace spend limit, so a limit is not a hard cap.

Good batch tasks include classification, short factual summaries, and review of
synthetic or public records. Give each request a stable `custom_id`. Start with
a small sample. Read every result and error before you process the full set.

## Limit cost

1. State the task, source, output fields, and review rule before you submit.
2. Estimate input and output token use with a small sample.
3. Pick the lowest-cost active model that meets the quality need.
4. Set a bounded `max_tokens`. Avoid extended thinking unless the task needs it.
5. Submit a small batch first. Check its output and actual token usage.
6. Check workspace usage after the job. Stop if spend or output quality differs
   from the estimate.

Batch input and output remain stored for up to 29 days. Do not send data that
must not be retained for this period.

Never use a large credit balance as a reason to send more data than the task
needs. Do not publish model output without human review.

## Official references

- [Claude API authentication and workspace selection](https://platform.claude.com/docs/en/manage-claude/authentication)
- [Message Batches API](https://platform.claude.com/docs/en/build-with-claude/batch-processing)
- [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Claude Console billing](https://platform.claude.com/settings/billing)
