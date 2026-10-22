# Cloudflare cost collector failure cases

Specify these cases before implementation.

- Missing credentials fail before network access.
- An existing output path fails without overwriting evidence.
- Server page limits differ from requested page sizes.
- Empty pages before the reported total fail as incomplete.
- Repeated pages fail instead of looping.
- HTTP failures and API errors fail without printing credentials or response bodies.
- GraphQL errors fail even when HTTP status is successful.
- Analytics at the result limit fail instead of reporting partial totals.
- Missing or null row metrics fail instead of becoming zero.
- Account resource names and IDs remain in private output only.
- Query counts never substitute for billable row counts.

Verify the executable against a local HTTP fixture before live use.
Save the terminal transcript outside the repository.

Billing extension cases, specified before implementation:

- Billing collection is opt-in and uses the endpoint's current billing period.
- Explicit billing API errors prevent a complete summary.
- Raw usage retains cumulative fields; daily billed costs are never summed.
- An unexpected billing result shape fails without a success summary.
