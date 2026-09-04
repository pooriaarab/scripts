# Worker launchers

One launcher per delegate route. Each takes a prompt and runs it against a
working directory, non-interactively, with writes enabled.

```bash
workers/verify-routes                     # 17*23 through every route
workers/w-gemini   <dir> "<prompt>"
workers/w-cursor   <dir> "<prompt>" [model]
workers/w-devin    <dir> "<prompt>" [model]
workers/w-pi       <dir> "<prompt>" [model]
workers/w-muse     <dir> "<prompt>"
```

## Why these exist

Every route fails the same way when invoked naively: **it exits 0 and changes
nothing.** That is the worst shape a delegate can have, because a job reads as
done. Four separate causes, one per route:

| Route | The trap |
|---|---|
| gemini | `gemini` on PATH is a zsh wrapper calling `_offrouter_proxy_up` and `_gemini_personal_impl`, which exist only in an interactive login shell. Outside one it prints `command not found`, says `falling back DIRECT`, and returns nothing. Its **text output is also empty** — only `-o json` carries the answer, in `.response`. |
| cursor-agent | `source cursor.env` in a subshell does not export, so the key never reaches the process. It then reports `Authentication required`, which reads as a login problem rather than a shell one. |
| devin | Refuses every write in non-interactive mode unless `--permission-mode dangerous` is passed, and **still exits 0**. |
| pi | Its zai key resolves through `zsh -lc "pi auth print-api-key"`, which fails when PATH does not carry `pi`. |

Each launcher calls the real binary by absolute path, so a shell function cannot
shadow it.

## Verify before you fan out

`workers/verify-routes` sends `17*23` through each route and checks for `391`.

Run it on a fresh session, after any CLI upgrade, and before dispatching a
batch. "Replies OK" is not evidence — three of these four will reply and change
nothing.

Quota is not a local problem and the launchers do not hide it. A route that is
authenticated and out of budget answers `resource_exhausted`; `verify-routes`
reports that as its own state, distinct from a broken invocation.
