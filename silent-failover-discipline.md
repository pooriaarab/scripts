# A working failover hides the failure it is protecting against

A fleet of automated jobs (a review action, a notify step, anything with a primary
credential and a backup) can go down all at once, hours after the real failure, because
the failover worked. This is not a CI-speed or CI-cost problem — it belongs here because
it is a monitoring gap, not a workflow-config one.

## What happened

A review action tried a primary token, then a backup, on every run. The primary had been
exhausted for hours. Nobody noticed, because every run still succeeded — it fell through
to the backup. Across roughly 48 repos, every run made the same fallthrough, so the
backup absorbed the entire fleet's load and exhausted too. The whole fleet then failed at
once, at the moment the second credential ran out, with no earlier warning.

**The lesson generalizes past tokens.** Any primary/backup pair — API keys, runner
labels, cache endpoints — has the same shape: the backup's job is to be invisible, so its
use is invisible too, until it also runs out.

## The exhausted-credential signature

Recognize it from the call shape when the model never actually ran, rather than waiting
for an explicit error:

- `is_error: true`
- `subtype: "success"` (the call layer reports success; the model layer did not run)
- `num_turns: 1`
- ~450–520 ms — too fast for a real model call
- `total_cost_usd: 0`
- `modelUsage` empty

Any call matching this shape spent no tokens and produced no output. Treat it as an
exhausted credential, not a fast success.

## The rule

**Alert on *use* of the backup, not only on failure of both.** A dashboard that only
tracks "did the job succeed" cannot see this failure mode — every run is green until the
moment both credentials are dead. Track which credential answered each call, and page on
the first time the backup answers, not on the first time nothing does.
