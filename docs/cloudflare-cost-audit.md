# Collect Cloudflare cost evidence

Run `cloudflare-cost-audit --help` for the command contract.
Requires Python 3 and process environment variables `CLOUDFLARE_ACCOUNT_ID`
and `CLOUDFLARE_API_TOKEN`. Use an approved credential loader.
The command never reads credential files.

```sh
./cloudflare-cost-audit --start 2026-10-01 --end 2026-10-21 \
  --output /private/audits/new-run --billing
```

The output parent must exist. The output directory must be new.
Keep output outside Git. Raw responses contain account resource details.
The directory uses mode `0700`; files use `0600`.

The command reads D1 metadata and GraphQL analytics. It never runs SQL.
Dates include both endpoints and use UTC. Token permissions must allow
D1 metadata and account analytics. Billing requires separate billing access.
Failures return a nonzero status. Only successful runs write `summary.json`.
An interrupted directory remains partial evidence; use a new directory to retry.

Inventory collection follows returned totals, not the requested page size.
Repeated IDs and premature empty pages fail. Analytics includes historical
IDs, because deleted preview databases can contribute to the period's usage.
A response at the analytics limit fails; narrow the requested interval.

`ranked.json` records billable rows separately from query counts.
Resource count and current storage do not measure historical row costs.
This command does not calculate invoices or collect every paid service.

`--billing` saves raw current-period data from the alpha billable usage API.
Its period can differ from the D1 dates. Keep `BillingPeriodStart` and currency.
Never sum daily `BilledCost` without checking the service's billing semantics.
A high-water meter can repeat charges across days.
Compare the latest `CumulatedContractedCost` per service, subscription, zone,
period, and currency against the invoice. Treat that comparison as an estimate.
The command intentionally produces no billing total.

Verify the command with `python3 cloudflare-cost-audit.e2e.py`.
The fixture runs the executable through its CLI against a local HTTP server.

Sources: [D1 inventory](https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/list/),
[D1 billing metrics](https://developers.cloudflare.com/d1/observability/billing/),
[billable usage](https://developers.cloudflare.com/api/resources/billing/subresources/usage/methods/paygo/).

For temporary experiments outside this read-only command, follow the
[bounded cleanup contract](cloudflare-cleanup-deadlines.md).


## Measure a proposed batch

Fewer database calls can accompany more billable reads. Measure both effects.

1. Capture D1 row counters for statements called through `.run()`, `.first()`,
   `.all()`, and every `.batch()` result. Do not assume each return type exposes
   metadata; instrument the underlying execution when needed.
2. Record calls, statements, reads, writes, R2 PUTs, and result correctness
   separately. Keep per-statement counters to locate expensive work.
3. Pin the source and payload. Use the same engine, data size, cleanup behavior,
   and changed content in both arms. Reject an unintended deduplicated workload.
4. Warm both arms, alternate paired runs, and retain every sample and failure.
   Record medians, tails, uncertainty, and overlapping work that limits timing.
5. Inspect the actual query plan when reads grow. A materialized candidate set
   can still be scanned once for each outer tenant row. Measure join-order
   alternatives with unchanged authorization predicates and accounting checks.
6. Recheck source identity after collection. Separate local service timings
   from HTTP latency, production observations, and invoice savings.

A read-cost reduction can trade away latency. Report the tradeoff before promotion.
Keep failed attempts as failures, even when later cleanup proves absence.
