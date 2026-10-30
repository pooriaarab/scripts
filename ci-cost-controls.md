# Reduce CI cost without blocking delivery

Cut repeated work before changing the compute provider. Keep proof for the
revision that can reach production.

## Separate the scheduler from the machines

| Component | What it controls |
| --- | --- |
| GitHub Actions | Workflow events, job dependencies, and runner selection |
| Self-hosted Boat pool | Machines that execute private jobs |
| Native Boat CI integration | A separate integration that can create machines per job |
| GitHub-hosted runners | Machines billed through GitHub, subject to plan allowances |

A workflow can use GitHub Actions and execute on Boat. Suspending the native
Boat integration does not remove a separate self-hosted pool.

Verify the fallback before suspending an integration. Check repository hooks,
runner labels, and a successful job on the retained pool. Keep fork code away
from private runners and credentials. Standard public jobs can use free
GitHub-hosted runners.

Check current [GitHub billing rules](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [runner prices](https://docs.github.com/en/billing/reference/actions-runner-pricing).
Record account usage by product and SKU. A small hosted metadata job can cost
less than keeping another machine online. That does not justify moving every
private build to hosted machines.

## Measure the complete bill

Record a matched baseline and after period. Include:

- Running machine time, including idle capacity and machine-size weights.
- Machine starts and any charge above included limits.
- Plan charges, included compute credit, and wallet replenishment.
- Saved snapshots, hosted artifacts, caches, and review inference.
- Delivery latency, useful completed jobs, failures, and cancellations.

Use [the release evidence procedure](ci-release-evidence.md) for the baseline.
The existing audit commands read GitHub data:

```bash
./ci-pr-latency --help
./ci-job-timings --help
./ci-cache-health --help
./ci-runner-audit --help
./fleet-ci-census --help
```

Keep raw output private. Job names and URLs can identify private projects.
Payments buy credit; they do not establish consumed usage. Count included
compute once. Report a short observed rate separately from a monthly invoice.
Do not promise a universal savings percentage.

## Choose where proof runs

Use this flow only after qualifying the local gate and deployment checks.
A green branch alone does not prove that merged changes compose.

| Path | Verification |
| --- | --- |
| Normal development | Local gate before push, cheap PR policy, actual deployment build and smoke |
| Experiment | Manual broad CI or an isolated preview when required |
| Production promotion | Broad checks on the production candidate and its exact revision |
| Queue candidate | Checks on the assembled candidate, where a queue exists |

Keep the local command and its real result with the change. Bind artifacts to
the source revision and external dependency inputs. Use short branches and
small changes. Merge additive migrations first. Use feature flags for an
incomplete user flow. Share site rules through code and configuration.

Keep required reviews and operator walks. Test results provide repeatable
evidence; they do not prove every possible behavior. Test selection needs its
own coverage qualification. Removing an automatic trigger does not authorize
an unqualified selector or deletion of existing tests.

### Remove repeated builds and waiting jobs

Check whether deployment already builds the real site. A generic build before
that deployment may repeat the same work.

A polling job occupies a machine while it waits. Remove that wait from a
qualified development path. Keep production protection. Prefer an event-driven
handoff when it can preserve the same revision and failure rules.

When production still uses a wait, bind its lookup to both branch and revision.
For a repository with `release` as its production branch, inspect the result:

```bash
gh run list --repo "$GITHUB_REPOSITORY" \
  --workflow ci.yml --branch release --commit "$SHA" --limit 1 \
  --json databaseId,status,conclusion
```

This command only reads a result. The deployment gate must require a completed
successful run. A successful run from another branch is insufficient.

Changing a wait to a skipped job changes dependency behavior. Verify these
cases before cutover:

| Case | Required behavior |
| --- | --- |
| Development wait deliberately skipped | Qualified development deployment can proceed |
| Production wait skipped, failed, or cancelled | Deployment stays blocked |
| Planner fails | Canary and remaining sites stay blocked |
| Required canary fails or skips | Remaining sites stay blocked |
| No canary exists | Remaining affected sites can proceed after valid planning |
| Affected-site list is empty | No site matrix starts |
| Workflow is cancelled | No new deployment stage starts |

An `always()` condition needs explicit failure and cancellation guards. Preserve
serialization, environment restrictions, migrations, smoke checks, and alerts.
Never cancel an active production deployment to reclaim a runner.

### Batch recurring checks

Replace one-job-per-site monitoring with a bounded batch when checks share a
runtime. Retain per-site outcomes. A missing, timed-out, or incomplete receipt
must not become a pass. Qualify both healthy sites and slow failures. Bound
concurrency and child deadlines so reporting finishes within the job deadline.

### Check review proof without paid inference

Use a deterministic PR policy to check reviewer identity, verdict, and evidence.
Use the existing [PR standards checker](pr-standards.md) where installed. Keep
its workflow active when disabling an inference bot. If it is absent, provide
an equivalent proof gate before claiming that enforcement remains.

A review label must not reactivate paid model calls. An independent review can
run through an authorized subscription or hub. Keep its result in the PR.
Map all consumers before revoking a shared model key.

## Shrink the pool after work drains

Read [the pool runbook](boat-runners.md) and
[the machine cost guide](box-cost-discipline.md) first.

1. Find automatic resume, warmup, and keepalive tasks.
2. Disable the relevant resume loop before stopping its machines.
3. Pause new lease acquisition through a supported drain mechanism.
4. Check actual runner processes and current leases.
5. Stop only a confirmed quiet machine, with a fresh check.
6. Restore lease acquisition if inspection or stopping fails.
7. Verify remaining capacity with a real useful job.

Machine state `idle` does not prove inactivity. A completed leased job does not
prove that its JIT runner is quiet. GitHub can assign another job to that runner.
Preserve active workers and their independent leases.

Use a reversible stop when files matter. `boat-pool down` also deletes its
machine. Check the provider's stopped-file retention before relying on it.
Keep snapshots within the selected plan allowance.

Default new task machines to the smallest qualified size and a bounded TTL.
Choose larger machines from measured memory or runtime needs. Keep enough warm
capacity for useful work, then measure queue time and idle cost again.

## Verify the result

Record the retained pool, billing settings, and native integration state.
Verify automatic top-up and plan credit separately. Turning top-up off can
stop work when credit runs out; choose the funding policy deliberately.

Run the local gate before push. Get the required independent review. After
merge, inspect the actual deployed revision and its smoke result. Confirm that
removed workflows did not start for that revision.

Report billed cost and delivery latency separately. Fewer occupied job seconds
do not immediately reduce a fixed pool's bill. Lower machine count or online
time produces that saving. A later passing retry does not erase its first
failure. Keep the evidence and its limits.
