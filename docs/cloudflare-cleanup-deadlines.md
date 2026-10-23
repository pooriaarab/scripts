# Bound temporary Cloudflare resources

This contract guides temporary cost experiments. It is not a cleanup command.
The read-only `cloudflare-cost-audit` executable does not create or delete resources.

## Fix the deadline before creation

Write the failure cases before implementing a cleanup process.
Include slow response bodies, retained applications, missing resources, wrong ownership,
changed inventories, invalid manifests, and interrupted processes.

Set one original deadline that includes setup, observation, and cleanup.
Arm an independent cleanup process before creating the first resource.
Verify its live heartbeat and audited source hash before each creation.
Use a monotonic clock inside the process. Never extend the original deadline.

A socket timeout does not bound the whole response.
A server can send bytes slowly and keep `json.load()` waiting.
Test that case through a real local HTTP server and subprocess.
Use an independent process guard to stop blocked work before the deadline.
Reserve time to terminate children and write durable incomplete status.

Save the manifest and heartbeat outside Git with private permissions.
Flush files and the containing directory when updating ownership and deadline state.
Accept credentials through process environment variables only.

## Keep ownership strict

Record each returned resource ID immediately after creation.
Check the actual ID and exact name through a provider GET before deletion.
Keep shared bindings outside the manifest. Reject redirects and ambiguous names.
Validate provider response schemas before live creation.

Follow returned pagination metadata through every inventory page.
Repeated IDs, changed totals, and premature empty pages block completion.
Provider inventories can change between requests, including just after deletion.
Preserve the failed snapshot. Collect fresh complete evidence before retrying.
Do not turn that failure into an empty inventory or successful cleanup.

Delete only the approved owned resources. Verify asynchronous deletion through GET.
Verify namespace absence after Worker deletion; avoid separate namespace deletion.
Keep cleanup incomplete while an owned resource remains or an API check fails.

## Preserve a repeatable artifact

Record the original clock, manifest, source hashes, heartbeat, and deletion responses.
Record exact ID absence and complete inventory checks separately.
Stop the independent process only after complete absence is verified.
Keep failed attempts beside the final result.

For container experiments, use the
installed `cloudflare-cost-audit` skill.
Skipped dispatch, actual sleep, and billed usage are separate measurements.
