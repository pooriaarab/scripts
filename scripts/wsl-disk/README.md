# WSL disk maintenance

Keep a self-hosted runner fleet's WSL2 disk off the OS drive. See the
[`self-hosted-runner-fleet`](../self-hosted-runner-fleet/) skill for the why; this is the
runnable how.

## `move-wsl-to-drive.ps1`

Move a distro's `ext4.vhdx` from the OS drive to a data drive. The vhdx only grows — WSL
never shrinks it — so a per-repository runner fleet fills the OS drive over time.

```powershell
# run elevated on the Windows host
.\move-wsl-to-drive.ps1 -Distro Ubuntu -TargetDir D:\wsl\Ubuntu
```

- Waits for running jobs to drain (up to `-DrainTimeoutMin`, default 30); `-Force` skips
  the wait and accepts that in-flight jobs fail and re-queue.
- Runners are systemd services inside the distro, so they move with it and reconnect on
  the next boot — no re-registration.

### Gotchas the script handles (and you should know about)

- **The built-in `wsl --manage --move` can hang on finalize** — it copies to the target
  and re-points the registry, then wedges before deleting the source, leaving the vhdx on
  both drives. The script verifies the registry points at the target and the copy exists,
  then deletes the stale source itself.
- **A stuck `wsl.exe` wedges the service.** Any wsl command issued mid-move can leave the
  service in `StopPending` and every later call hangs. The Store build runs as
  **`WSLService`**, not the legacy `LxssManager` — restart that one to clear it.
- **Cold-start to boot systemd.** After the move the script runs `wsl --terminate` then
  invokes the distro, so systemd boots and auto-starts the runners. A plain
  `wsl -d <distro> -e ...` can enter without systemd, and then `systemctl` reports
  `Failed to connect to bus`.
