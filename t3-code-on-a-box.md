# Running T3 Code on an ascii.dev Box

**Recommendation: run the whole T3 Code server on a Box and reach it over
`box host`.** It is the only one of the three plausible shapes that works, and
it is tested below.

T3 Code drives coding agents from a GUI, gives each thread its own git worktree,
and does diff review, commit and PR from the browser. An ascii.dev Box is a
Linux VM with sudo. Putting the server on the Box moves every agent, worktree
and build off the laptop.

## Why this shape and not the others

T3 has exactly one runtime boundary. Its own internals doc puts it plainly:
"The server is the execution boundary: every provider process, terminal, git
operation, and filesystem read happens there, never in the client." Remoteness
is a connection concern, never a split runtime. That single sentence decides
all three options.

| Shape | Verdict |
|---|---|
| **T3 server on the Box, reached over `box host`** | **Works. Recommended.** Tested end to end below. |
| Local T3, provider binary swapped for a wrapper that shells into a Box | **Dead end.** Do not build this. |
| Tailscale on the Box | Works in principle, buys nothing here. |

### The wrapper shape is a trap, and it fails quietly

T3's provider `binaryPath` is an unvalidated string, so a wrapper script that
shells out to `box exec` **is accepted and does appear to run**. It still does
not work. The server spawns the agent with a local `cwd` and then does git
status, diffs, checkpoints and terminals against its own disk. An agent editing
files inside a Box leaves the local worktree untouched, so diff review, commit
and PR creation all see an empty changeset. You get a green-looking thread that
produced nothing. Skip it.

### Tailscale is unnecessary, not impossible

A Box can almost certainly join a tailnet: it is a KVM virtual machine, not a
container (`systemd-detect-virt` returns `kvm`), `/dev/net/tun` exists, sudo is
passwordless, and systemd is running. All four verified.

But ascii's docs never mention Tailscale, WireGuard or VPNs at all, so it is
unsupported, and it solves a problem `box host` already solves better. SSH into
a Box is by raw IP, and machine identity — hostname, network config, SSH host
keys — is explicitly excluded from snapshots. A resumed Box lands on new
hardware, so its IP and host key change and any static `~/.ssh/config` entry
breaks. The `box host` HTTPS subdomain is stable and, per the docs, returns the
same URL and token after a resume. Use the thing that survives.

## What I tested

On a `small` Box (2 vCPU, 4 GB), with nothing installed beyond the base image:

```
$ box exec <id> "node --version; git --version; which gcc make"
v24.18.1
git version 2.43.0
/usr/bin/gcc
/usr/bin/make
```

Node 24 clears T3's `^22.16 || ^23.11 || >=24.10` engine requirement, and the C
toolchain is present, which matters because T3 builds `node-pty` from source and
fails on a minimal image without it.

Starting the server:

```
$ box exec <id> --detach "cd /home/user && nohup npx --yes t3@latest serve \
    --host 0.0.0.0 --port 3773 --base-dir /home/user/.t3 > t3serve.log 2>&1 &"

# t3serve.log
[01:24:57.412] INFO (#354): Listening on http://0.0.0.0:3773
[01:24:57.450] INFO (#353): provider.session.reaper.started
T3 Code server is ready.
Connection string: http://<box-ip>:3773
Pairing URL: http://<box-ip>:3773/pair#token=<token>
```

Exposing it:

```
$ box host <id> 3773 --json
{"access":"private","isProtected":true,"port":3773,
 "url":"https://<subdomain>-3773.on.ascii.dev?_token=<token>"}
```

Reaching it from the laptop:

| Request | Result |
|---|---|
| `GET /` with no token | `403` |
| `GET /?_token=...` | `302`, then `200`, 19,884 bytes of the T3 single-page app |
| `POST /oauth/token`, JSON body | `415 Unsupported content-type` |
| `POST /oauth/token`, malformed grant | `400`, with `access-control-allow-origin: *` |

The last two matter most. Those are T3's own auth control plane answering
protocol-level errors through the tunnel, and that CORS header is set by T3's
server, not by the proxy. The tunnel carries the real application, not just
static assets.

**Bind `0.0.0.0`, not `127.0.0.1`.** `box host` connects from outside the
process, so a loopback-only listener is unreachable through it.

**What I did not test:** completing the browser pairing handshake, and
`box resume` preserving the hosted URL. The URL survived every check I ran while
the Box stayed up; resume stability is documented but unverified here.

## Setting it up

```bash
# 1. A long-lived Box. Auto-stop must be off, or the server dies on the TTL.
box new --type default --no-auto-stop

# 2. Mark it so the reaper never touches it. See below.
box exec <id> "touch /home/user/.box-reap-keep"

# 3. Authenticate the agent CLIs ON THE BOX. Your laptop's logins do not travel.
box ssh <id>
claude auth login            # repeat per CLAUDE_CONFIG_DIR you want
codex login

# 4. Run the server under systemd so it survives stop/resume.
#    A detached process does not; /etc is snapshotted, so a unit does.
npx t3@latest service install

# 5. Expose it and pair from the browser.
box host <id> 3773
```

## The two constraints, handled

**"T3 worktrees have no bootstrap hook" is no longer true.** T3 reads a checked-in
`t3.json` at the repo root, and each entry in its `scripts[]` array takes
`runOnWorktreeCreate: true`, which runs after a worktree is created for a new
thread. The script gets `T3CODE_PROJECT_ROOT` and `T3CODE_WORKTREE_PATH` in its
environment and runs with the worktree as its cwd. This is the direct analogue
of Superset's `.superset/config.json`. T3's own repo uses it to install deps and
symlink `.env`:

```json
{
  "scripts": [
    {
      "name": "Setup Worktree",
      "command": "npm ci && ln -sf $T3CODE_PROJECT_ROOT/.env .env",
      "runOnWorktreeCreate": true
    }
  ]
}
```

Add one to each repo you run threads against and every fresh worktree bootstraps
itself. Nothing about running on a Box changes this.

**One `CLAUDE_CONFIG_DIR` per provider entry, fixed at thread start.** This is
still true, and it works the same on a Box: add one provider instance per config
directory and pick the one with headroom when you start a thread. The difference
is that the config directories must exist and be authenticated **on the Box**.
Copying `~/.claude-personal` from the laptop is not part of the flow; log in
again on the Box, once per directory.

## Cost, and the reaper interaction

A `default` Box left running costs about $26 a month, a `small` about $13. That
is the price of an always-on control plane, and it only makes sense if you
actually leave it up.

**A T3 server Box will be reaped if you let it.** An idle T3 server sits at
roughly 0-2% CPU, which is indistinguishable from an abandoned machine. During
testing, `box-reap` marked the T3 Box `STOP` on exactly that basis. Two fixes,
use either:

```bash
box exec <id> "touch /home/user/.box-reap-keep"       # opt out entirely
box exec <id> "touch /home/user/.box-reap-heartbeat"  # or heartbeat on a timer
```

See [box-cost-discipline.md](box-cost-discipline.md).
