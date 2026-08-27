# Machine onboarding

Add a Windows, macOS, Linux, or Android device to a personal tailnet and give it a
role: controller, worker, or consumer. This is the layer *under*
[`self-hosted-runner-fleet`](../self-hosted-runner-fleet/) and
[`agent-devbox`](../agent-devbox/) — those assume a machine you can already reach.
This is how it becomes reachable, and how you stop it reaching where it should not.

## Roles

A tailnet of personal machines is not a mesh of equals. Give every node exactly one
role and the rest of the design follows.

- **Controller** — the machine you sit at. Runs the Deskflow/KVM *server*, holds the
  SSH private keys, dispatches work. Nothing else may log into it.
- **Worker** — an always-on or often-on box that accepts SSH, runs Actions runners,
  holds repo checkouts, serves dev servers. It receives; it never initiates toward
  the controller.
- **Consumer** — a phone or tablet. Joins the tailnet to *reach* services. Cannot host
  anything.

## What each OS can actually do

| | tailnet member | inbound SSH | Actions runner | repo checkouts | dev server host | Deskflow client | Deskflow server |
|---|---|---|---|---|---|---|---|
| **Linux** | yes | `sshd` | yes, native — the best worker | yes | yes | yes (see input-group note) | yes |
| **macOS** | yes | Remote Login | yes, native | yes | yes | yes | yes — the usual controller |
| **Windows** | yes | OpenSSH Server capability | yes, **inside WSL2** | yes | yes | yes | possible, rarely wanted |
| **Android** | yes | no | no | no | no | no | no |

**Android is a consumer, not a worker, and no amount of setup changes that.** The
Tailscale app joins the tailnet and can browse `http://100.x.y.z:3000` on a worker,
which is genuinely the point of putting a phone on the tailnet. It cannot run a
runner, cannot hold a checkout, cannot be a KVM client. Two further limits worth
knowing before you plan around it: Android allows exactly **one** active VPN, so
Tailscale and a corporate VPN are mutually exclusive on that device, and an
SSH server via Termux dies whenever the OS reclaims the app. Treat the phone as a
screen.

**Windows workers run the runner inside WSL2, not on Windows.** Workflows written
for `ubuntu-latest` use bash and POSIX paths and will fail natively. WSL2 also
brings its own failure mode that does not announce itself — see
[`self-hosted-runner-fleet`](../self-hosted-runner-fleet/) for the `vmIdleTimeout=-1`
plus S4U-keepalive pair. Skipping that gives you jobs that die mid-run with `null`
steps.

**Linux desktop as a Deskflow client** needs the user in the `input` group and a
`uinput` rule, and Wayland restricts synthetic input in ways X11 does not. If a
Linux box must accept keyboard and mouse from the controller, log it into an X11
session.

## Enforce the control direction in ACLs, not in habit

If the rule is "the controller drives the workers and no worker reaches back", write
it into the tailnet ACL. Convention decays; an ACL does not. Tag on join, then:

```jsonc
{
  "tagOwners": { "tag:ctrl": ["autogroup:admin"], "tag:worker": ["autogroup:admin"] },
  "acls": [
    // controller reaches every worker
    { "action": "accept", "src": ["tag:ctrl"], "dst": ["tag:worker:22,3000,5173,24800"] },
    // workers reach each other for build coordination, and nothing else
    { "action": "accept", "src": ["tag:worker"], "dst": ["tag:worker:22"] }
    // no rule grants any src -> tag:ctrl. That is the point.
  ]
}
```

With no rule whose `dst` is `tag:ctrl`, a compromised worker cannot open a socket to
the controller at all. This is stronger than "we did not install a key there", and it
survives someone later installing one.

Note that Deskflow inverts the intuition: the **controller listens on 24800** and the
worker connects *to it*. So the KVM does need worker → controller on that one port.
Either open exactly `tag:ctrl:24800` to `tag:worker`, or accept that the KVM is the
one sanctioned inbound path and keep everything else closed. Do not open it wider
because the KVM "needs the network".

## Use

Idempotent — safe to re-run. Neither script installs a credential pointing at the
controller.

```sh
# Linux / macOS
./onboard.sh --hostname studio-linux --role worker --tag tag:worker
```

```powershell
# Windows (elevated)
.\onboard.ps1 -Hostname laptop-srep0stq -Role worker -Tag tag:worker
```

Both do the same four things: set the OS hostname *before* joining, join the tailnet
with the tag, enable inbound SSH scoped to the tailnet CIDR, then print a capability
report. They deliberately stop before installing runners or checkouts — that is
`self-hosted-runner-fleet`'s job, and it wants a machine that already answers on 22.

## The five that cost real time

1. **Rename before joining.** Tailscale takes the node name from the OS hostname at
   join. Join as `DESKTOP-8F2K1A` and that string is in your ACLs, your SSH config,
   and your runner labels forever. Renaming afterwards leaves a stale node that still
   holds the name you want, and you have to delete it in the admin console before the
   good name frees up.

2. **Disable key expiry on every worker.** Node keys expire after 180 days by default.
   A headless worker does not prompt anybody — it simply drops off the tailnet, and
   what you observe is a runner that went offline and CI that queues forever, six
   months after you last thought about Tailscale. Admin console → the machine →
   Disable key expiry. Do this at onboarding, not when it bites.

3. **Scope the SSH firewall rule to `100.64.0.0/10`.** A laptop that joins a tailnet
   also joins airport Wi-Fi. An unscoped port-22 allow rule is a listening SSH server
   on every hostile network the machine ever sees. The scripts set this; if you open
   SSH by hand, set it by hand.

4. **MagicDNS on Windows fails quietly and specifically.** `tailscale status` reports
   `Tailscale failed to set the DNS configuration of your device: Access is denied`
   when the service cannot write DNS settings. Everything else keeps working, so it
   reads as fine — but `worker-hostname:3000` will not resolve, only `100.x.y.z:3000`
   will. Check the health section on every Windows onboard and either fix the service
   privileges or standardise on IPs for that machine.

5. **A laptop worker sleeps.** Lid closed means off the tailnet, runner offline, jobs
   queued. Either set the power plan to stay awake on AC and accept the battery cost,
   or — better — give the laptop its own runner label and pin nothing to it that a
   pull request waits on. Capability, not obligation.
