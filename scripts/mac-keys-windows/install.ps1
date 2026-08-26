#Requires -Version 5.1
<#
.SYNOPSIS
    Installs MacKeys - macOS keyboard behaviour on a Windows host.

.DESCRIPTION
    Idempotent. Installs AutoHotkey v2 and QuickLook if missing, copies
    MacKeys.ahk into place, registers both at login, and starts them.

    Assumes a Mac drives this host over Deskflow, so the Mac's Command key
    arrives as the Windows key. If Command instead arrives as Alt (a directly
    paired Apple keyboard with Boot Camp drivers can do this), swap the '#'
    prefixes in MacKeys.ahk for '!'.

.PARAMETER FreeWinL
    Sets DisableLockWorkstation under HKCU policies so that AutoHotkey can see
    Win+L, which makes Cmd+L reach the browser address bar. Windows reserves
    Win+L below the level any keyboard hook can intercept, so this is the only
    way. Locking stays available on Cmd+Ctrl+Q, the real macOS shortcut.
    Off by default because it disables the Win+L lock gesture.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -FreeWinL
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\MacKeys",
    [switch]$FreeWinL,
    [switch]$SkipPackages
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Note { param([string]$m) Write-Host "    $m" -ForegroundColor DarkGray }

# --- packages ---------------------------------------------------------------
$ahkExe = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe"
$qlExe  = "$env:LOCALAPPDATA\Programs\QuickLook\QuickLook.exe"

if (-not $SkipPackages) {
    if (-not (Test-Path $ahkExe)) {
        Write-Step "Installing AutoHotkey v2"
        winget install --exact --id AutoHotkey.AutoHotkey `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
    } else {
        Write-Note "AutoHotkey v2 already present"
    }

    if (-not (Test-Path $qlExe)) {
        Write-Step "Installing QuickLook (spacebar file previews)"
        winget install --exact --id QL-Win.QuickLook `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
    } else {
        Write-Note "QuickLook already present"
    }
}

if (-not (Test-Path $ahkExe)) {
    throw "AutoHotkey v2 not found at $ahkExe. Install it, or pass -SkipPackages and place it there."
}

# --- script -----------------------------------------------------------------
Write-Step "Installing MacKeys.ahk to $InstallDir"
$null = New-Item -ItemType Directory -Path $InstallDir -Force
$src = Join-Path $PSScriptRoot 'MacKeys.ahk'
if (-not (Test-Path $src)) { throw "MacKeys.ahk not found beside this installer." }
Copy-Item $src (Join-Path $InstallDir 'MacKeys.ahk') -Force

$readme = Join-Path $PSScriptRoot 'README.md'
if (Test-Path $readme) { Copy-Item $readme (Join-Path $InstallDir 'README.md') -Force }

# --- run at login -----------------------------------------------------------
Write-Step "Registering at login"
$startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$ws = New-Object -ComObject WScript.Shell

$lnk = $ws.CreateShortcut("$startup\MacKeys.lnk")
$lnk.TargetPath = $ahkExe
$lnk.Arguments = "`"$InstallDir\MacKeys.ahk`""
$lnk.WorkingDirectory = $InstallDir
$lnk.Description = 'macOS keyboard behaviour for Windows'
$lnk.Save()
Write-Note "MacKeys.lnk"

if (Test-Path $qlExe) {
    $lnk2 = $ws.CreateShortcut("$startup\QuickLook.lnk")
    $lnk2.TargetPath = $qlExe
    $lnk2.Description = 'Spacebar file previews'
    $lnk2.Save()
    Write-Note "QuickLook.lnk"
}

# --- optional: let AutoHotkey see Win+L -------------------------------------
if ($FreeWinL) {
    Write-Step "Freeing Win+L so Cmd+L reaches the address bar"
    $pol = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path $pol)) { $null = New-Item -Path $pol -Force }
    $null = New-ItemProperty -Path $pol -Name DisableLockWorkstation `
        -Value 1 -PropertyType DWord -Force
    Write-Note "Lock the screen with Cmd+Ctrl+Q from now on"
}

# --- start now --------------------------------------------------------------
Write-Step "Starting"
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $ahkExe } |
    Stop-Process -Force -Confirm:$false
Start-Sleep -Milliseconds 400
Start-Process -FilePath $ahkExe -ArgumentList "`"$InstallDir\MacKeys.ahk`""

if ((Test-Path $qlExe) -and -not (Get-Process QuickLook -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $qlExe
}

Start-Sleep -Seconds 2
$ahk = Get-Process AutoHotkey64 -ErrorAction SilentlyContinue
if (-not $ahk) {
    Write-Warning "MacKeys exited immediately - the script failed to load."
} elseif ($ahk | Where-Object { $_.MainWindowHandle -ne 0 }) {
    Write-Warning "MacKeys opened a dialog - probably a script error. Check the tray."
} else {
    Write-Host "MacKeys is running. Ctrl+Alt+F12 suspends it." -ForegroundColor Green
}
