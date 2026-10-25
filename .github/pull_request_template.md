Closes #

## What

<!-- One to three sentences. What changed, in plain words. Delete this comment. -->

## Why

<!-- The problem from the issue above, and why this is the fix. Delete this comment. -->

## How I verified

<!-- Name the commands you ran and what they returned. "Tested locally" and "N/A"
     both fail the check, because neither tells a reviewer anything. Delete this comment. -->

```text
bun test      ->
bun run build ->
```

## Review

<!-- A second model, not the one that wrote the change, reads the diff. Paste
     its two lines here, or post them as a pull request comment. Delete this
     comment and write the lines for real. An example that does not count
     while it stays inside this comment:
     Reviewed-by: codex:gpt-6-astra
     Verdict: 0 major -->

Assisted-by: <agent>:<model>

<!--
  One issue. One PR. One concern. Under 500 counted lines.
  Lockfiles, build output, snapshots, and migrations do not count against the cap.
  There is no label that clears the cap. Split the change.
  One Assisted-by line per contributor. Repeat the line for each contributor:
  Assisted-by: <agent>:<model>
  Assisted-by: <agent>:<model>
  A comma-separated list on one line fails the check.
-->
