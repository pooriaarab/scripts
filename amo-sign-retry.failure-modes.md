# amo-sign-retry failure modes

addons.mozilla.org (AMO) throttles new add-on submissions per account. The
signing step of a release workflow then fails with a line such as
`Expected available in 873 seconds`. Signing many new add-ons can take hours.
`amo-sign-retry` watches the newest run of a release workflow in each repo,
waits out each reported window, and re-runs the failed jobs.

A re-run only helps when the workflow is safe to run again. If the workflow
publishes to npm before it signs, it must skip `npm publish` when that exact
version is already on npm. Otherwise the re-run stops at the publish step.

This file lists every way the tool can fail. The tests in
`amo-sign-retry.test.sh` cover each row marked "tested".

| # | Failure | Wanted behavior | Tested |
|---|---|---|---|
| 1 | No repo is given, or a repo is not `OWNER/NAME`. | Print usage, exit 1. | yes |
| 2 | The workflow has no runs. | Report `no run` for that repo. Count it as a failure. | yes |
| 3 | The newest run is still in progress. | Keep watching. With `--once`, report it as waiting. | yes |
| 4 | The run succeeded. | Report `signed` and stop watching that repo. | yes |
| 5 | The run failed before the signing step (build, tests, or publish). | Report it, do not re-run, count it as a failure. A re-run cannot fix a red build. | yes |
| 6 | The signing step failed, and the log has no throttle window. | Report it, do not re-run, count it as a failure. | yes |
| 7 | The signing step was throttled. | Wait until the run's end time plus the window plus `--margin`, then `gh run rerun --failed`. | yes |
| 8 | The throttle repeats with no end. | Stop after `--max-attempts` re-runs and count it as a failure. | yes |
| 9 | One repo's long window blocks the other repos. | Each repo has its own due time. The loop sleeps only until the next due time, capped at `--interval`. | no, timing |
| 10 | `--once` sleeps, so a cron job hangs. | `--once` never sleeps. It re-runs only the repos whose window has passed, and exits 3 while any repo still waits. | yes |
| 11 | The tool reads or prints a token. | It reads none. All calls go through the `gh` login. | no, by design |
