<#
.SYNOPSIS
  Move a WSL2 distro's virtual disk off the OS drive onto a data drive.
.DESCRIPTION
  A self-hosted runner fleet keeps its checkouts, caches, and build output inside the
  WSL2 distro's ext4.vhdx. That disk only grows — WSL never shrinks it — so it fills the
  OS drive over time. This relocates the whole distro to a data drive. The runners are
  systemd services inside the distro, so they move with it and reconnect on next boot.

  Idempotent: if the distro already lives at the target, it reports and exits. Refuses to
  move while a job is running unless -Force. Waits for the fleet to drain by default.

  Windows PowerShell 5.1 compatible: no &&, no ternary, no null-coalescing.
  Run elevated (the registry re-point and vhdx delete need it).
.EXAMPLE
  .\move-wsl-to-drive.ps1 -Distro Ubuntu -TargetDir D:\wsl\Ubuntu
.EXAMPLE
  .\move-wsl-to-drive.ps1 -Distro Ubuntu -TargetDir D:\wsl\Ubuntu -Force
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Distro,
  [Parameter(Mandatory = $true)][string]$TargetDir,
  [int]$DrainTimeoutMin = 30,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "   $m" }
function Fail($m) { Write-Error $m; exit 1 }

# --- locate the distro registration -----------------------------------------
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$reg = Get-ChildItem $lxss | Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $Distro }
if (-not $reg) { Fail "distro '$Distro' not found under $lxss" }
$base = (Get-ItemProperty $reg.PSPath).BasePath
Note "current BasePath: $base"

if ($base -ieq $TargetDir) { Say "already at $TargetDir — nothing to do"; exit 0 }

# --- refuse to clobber a job in flight ---------------------------------------
$busy = (wsl.exe -d $Distro -u root -e bash -c "pgrep -f Runner.Worker | wc -l") 2>$null
$busy = ("$busy" -replace '\D', '')
if ($busy -and [int]$busy -gt 0) {
  if ($Force) {
    Note "WARNING: $busy job(s) running — -Force set, they will fail and re-queue"
  } else {
    Say "draining: waiting up to $DrainTimeoutMin min for $busy job(s) to finish"
    $deadline = (Get-Date).AddMinutes($DrainTimeoutMin)
    while ((Get-Date) -lt $deadline) {
      $n = (wsl.exe -d $Distro -u root -e bash -c "pgrep -f Runner.Worker | wc -l") 2>$null
      $n = ("$n" -replace '\D', '')
      if (-not $n -or [int]$n -eq 0) { break }
      Start-Sleep -Seconds 20
    }
    $n = ("$((wsl.exe -d $Distro -u root -e bash -c 'pgrep -f Runner.Worker | wc -l'))" -replace '\D', '')
    if ($n -and [int]$n -gt 0) { Fail "still $n job(s) running after $DrainTimeoutMin min — re-run with -Force or wait" }
  }
}

# --- do the move -------------------------------------------------------------
Say "stopping runner services (drain), then shutting WSL down"
wsl.exe -d $Distro -u root -e bash -c "systemctl stop 'actions.runner.*' 2>/dev/null; true" | Out-Null
wsl.exe --shutdown
Start-Sleep -Seconds 8

$srcVhd = Join-Path $base 'ext4.vhdx'
New-Item -ItemType Directory -Force -Path (Split-Path $TargetDir -Parent) | Out-Null

Say "wsl --manage $Distro --move $TargetDir  (copies the whole vhdx — takes a while)"
$moveOut = & wsl.exe --manage $Distro --move $TargetDir 2>&1 | Out-String
Note ("move output: " + $moveOut.Trim())

# --- verify + finalize (the built-in move can hang before deleting source) ---
$newBase = (Get-ItemProperty $reg.PSPath).BasePath
Note "BasePath now: $newBase"
if ($newBase -ine $TargetDir) {
  Fail "registry BasePath did not update to $TargetDir — inspect manually before deleting anything"
}

$tgtVhd = Join-Path $TargetDir 'ext4.vhdx'
if (-not (Test-Path $tgtVhd)) { Fail "target vhdx missing at $tgtVhd — do NOT delete the source" }

# registry points at the target and the copy exists — safe to reclaim the source
if (Test-Path $srcVhd) {
  Say "reclaiming OS drive: deleting stale source $srcVhd"
  Get-Process wsl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Remove-Item $srcVhd -Force -ErrorAction SilentlyContinue
  if (Test-Path $srcVhd) { Note "could not delete source (locked) — restart WSLService, then delete $srcVhd by hand" }
  else { Note "source deleted" }
}

# --- cold-start so systemd boots and the runners come back -------------------
Say "cold-starting $Distro (boots systemd -> runner services auto-start)"
wsl.exe --terminate $Distro | Out-Null
Start-Sleep -Seconds 3
wsl.exe -d $Distro -u root -e bash -c "for i in \$(seq 1 12); do systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 5; done; systemctl start 'actions.runner.*' 2>/dev/null; true" | Out-Null
$running = ("$((wsl.exe -d $Distro -u root -e bash -c 'systemctl list-units "actions.runner.*" --state=running --no-legend --no-pager | wc -l'))" -replace '\D', '')
Say "done — runner services running: $running"
Note "if 0, systemd was still initializing; re-check with: wsl -d $Distro -u root -e systemctl start 'actions.runner.*'"
