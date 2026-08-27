<#
.SYNOPSIS
  Join a Windows machine to the tailnet and give it a role.
.DESCRIPTION
  Idempotent: re-running reconciles rather than duplicating. Installs nothing that
  can reach the controller. Stops short of installing Actions runners — that is
  scripts/self-hosted-runner-fleet, which wants a machine already answering on 22.

  Windows PowerShell 5.1 compatible: no &&, no ternary, no null-coalescing.
.EXAMPLE
  .\onboard.ps1 -Hostname laptop-srep0stq -Role worker -Tag tag:worker
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Hostname,
  [ValidateSet('worker', 'controller', 'consumer')][string]$Role = 'worker',
  [string]$Tag = '',
  [string]$TailnetCidr = '100.64.0.0/10',
  [string]$WslDistro = 'Ubuntu'
)

$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "   $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an elevated PowerShell. Renaming the computer, the OpenSSH capability, and firewall rules all require it.'
}

$rebootNeeded = $false

# --- hostname, before the join ------------------------------------------------
# Tailscale derives the node name from the OS hostname at join time. Joining as
# DESKTOP-8F2K1A puts that string in the ACLs and SSH config permanently, and
# renaming later strands a node that still holds the name you wanted.
Say 'hostname'
if ($env:COMPUTERNAME -ieq $Hostname) {
  Note "already $Hostname"
} else {
  Note "$env:COMPUTERNAME -> $Hostname"
  Rename-Computer -NewName $Hostname -Force
  $rebootNeeded = $true
  Note 'Rename staged. Reboot BEFORE joining the tailnet, then re-run this script.'
}

# --- tailscale ----------------------------------------------------------------
Say 'tailscale'
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id tailscale.tailscale --silent --accept-package-agreements --accept-source-agreements
  } else {
    throw 'Tailscale not installed and winget unavailable. Install from https://tailscale.com/download/windows and re-run.'
  }
}

if ($rebootNeeded) {
  Note 'Skipping join until the rename has taken effect. Reboot, then re-run.'
} else {
  $status = & $ts status 2>&1
  if ($LASTEXITCODE -eq 0) {
    Note 'already joined'
  } else {
    $upArgs = @('up', '--hostname', $Hostname)
    if ($Tag) { $upArgs += @('--advertise-tags', $Tag) }
    & $ts @upArgs
  }
  & $ts status
}

# --- inbound SSH, workers only, tailnet only ----------------------------------
if ($Role -eq 'worker') {
  Say "inbound ssh (scoped to $TailnetCidr)"
  $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
  if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd

  # Key-only auth.
  $cfg = 'C:\ProgramData\ssh\sshd_config'
  if (Test-Path $cfg) {
    $text = Get-Content $cfg -Raw
    $text = $text -replace '(?m)^\s*#?\s*PasswordAuthentication\s+\w+', 'PasswordAuthentication no'
    Set-Content -Path $cfg -Value $text -Encoding utf8
    Restart-Service sshd
  }

  # Windows Firewall's default OpenSSH rule allows port 22 from ANY address, which
  # means a listening SSH server on every hostile Wi-Fi this machine ever joins.
  # Replace it with a tailnet-scoped rule rather than adding alongside it.
  Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
    Disable-NetFirewallRule
  $ruleName = 'Tailnet-SSH-In'
  Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 22 -RemoteAddress $TailnetCidr | Out-Null
  Note "port 22 allowed from $TailnetCidr only"

  # Dev servers the controller will browse. Same scoping.
  $devName = 'Tailnet-Dev-In'
  Get-NetFirewallRule -DisplayName $devName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $devName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 3000, 5173 -RemoteAddress $TailnetCidr | Out-Null
  Note 'ports 3000 and 5173 allowed from the tailnet (bind dev servers to 0.0.0.0)'

  # --- WSL2, because a Windows worker runs the runner inside it ---------------
  Say 'wsl2'
  $distros = (wsl.exe -l -q) -replace "`0", '' 2>$null
  if ($distros -notmatch [regex]::Escape($WslDistro)) {
    Note "installing $WslDistro (this reboots on some builds)"
    wsl.exe --install -d $WslDistro
  } else {
    Note "$WslDistro present"
  }

  # systemd, without which the runner's ./svc.sh install has nothing to install into.
  $wslConf = "[boot]`nsystemd=true`n"
  wsl.exe -d $WslDistro -u root -- bash -lc "grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null || printf '%s' '$wslConf' >> /etc/wsl.conf"
  Note 'systemd=true ensured in /etc/wsl.conf'

  # A WSL2 that idles out mid-job kills the job, and the symptoms never say WSL:
  # null steps after a successful checkout, runs stuck queued, API reporting
  # offline busy=true. See scripts/self-hosted-runner-fleet. Both holders needed.
  $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
  if ((-not (Test-Path $wslConfig)) -or ((Get-Content $wslConfig -Raw) -notmatch 'vmIdleTimeout')) {
    Add-Content -Path $wslConfig -Value "[wsl2]`nvmIdleTimeout=-1" -Encoding utf8
    Note 'vmIdleTimeout=-1 written; run wsl.exe --shutdown while the fleet is IDLE to apply'
  } else {
    Note 'vmIdleTimeout already set'
  }
  Note 'Second holder (the S4U keepalive task) is set up by self-hosted-runner-fleet.'
}

# --- report -------------------------------------------------------------------
Say 'capability report'
$ip = 'unknown'
if (Test-Path $ts) {
  $ipOut = & $ts ip -4 2>$null
  if ($ipOut) { $ip = ($ipOut | Select-Object -First 1) }
}
[pscustomobject]@{
  Hostname     = $Hostname
  Role         = $Role
  TailscaleIP  = $ip
  Tag          = $(if ($Tag) { $Tag } else { 'none' })
  InboundSSH   = $(if ($Role -eq 'worker') { "yes, $TailnetCidr only" } else { 'no' })
  RunnerHost   = $(if ($Role -eq 'worker') { "yes, inside WSL2 ($WslDistro)" } else { 'no' })
  RebootNeeded = $rebootNeeded
} | Format-List

if (Test-Path $ts) {
  $health = & $ts status 2>&1 | Out-String
  if ($health -match 'failed to set the DNS configuration') {
    Write-Warning @'
Tailscale cannot write this machine's DNS configuration ("Access is denied").
Everything else keeps working, so this reads as fine - but MagicDNS names will
not resolve here. Address other nodes by their 100.x IP until the Tailscale
service has the privileges it needs.
'@
  }
}

Write-Host @"

Next, by hand, once:
  1. Admin console -> this machine -> Disable key expiry. Node keys expire after
     180 days and a headless worker drops off the tailnet without telling anyone.
  2. Put the CONTROLLER's public key in C:\ProgramData\ssh\administrators_authorized_keys
     - NOT in the user's .ssh\authorized_keys. Windows ignores the user file for
     accounts in the Administrators group, and that file needs restricted ACLs
     (SYSTEM and Administrators only) or sshd refuses it silently. This is the
     usual reason Windows key auth "just does not work".
     Do not generate a key here that points back at the controller.
  3. Runners and checkouts: see scripts/self-hosted-runner-fleet.
"@
