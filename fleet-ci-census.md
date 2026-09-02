# fleet-ci-census

Answers "how long is CI taking, per repo, and where is the bottleneck"
with numbers that can be compared across time.

Wall time, not billable minutes. A check that sits in the runner queue
for 35 minutes is the number that says where to spend effort. Billable
minutes need one `/actions/runs/{id}/timing` request per run, so they
stay behind `--timing`.

```bash
./fleet-ci-census                         # 26 newest repos by pushedAt
./fleet-ci-census pooriaarab/scripts      # one repo
./fleet-ci-census --markdown              # table ranked by total minutes
./fleet-ci-census --timing                # also fetch billable minutes
```

JSON is the default. `--markdown` prints a ranked table sorted by total
minutes — that column is the one that says where to spend effort.

## Page cap

The Actions list API is newest-first and stops at `--pages` × 100 runs
(default 300). A repo whose fetched count equals that cap is a **floor,
not a total**. Both outputs mark it. Treating 300 as a complete count
understates the busiest repos in the fleet.

## Duration clamp

A cancelled job that never finished can keep `updated_at` moving for
hours. That span is a stuck row, not CI time. Runs longer than 6 hours
do not enter the percentiles.
