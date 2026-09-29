#requires -Version 5.1
<#
.SYNOPSIS
    Replaces your installed Zed with the RTL-patched build (or reverts).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -DisableAutoUpdate
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -LocalExe C:\zed-src\target\release\zed.exe
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -Revert
#>
[CmdletBinding()]
param(
    [string]$ZedExe = "",
    [string]$Tag = "rolling",                 # release tag to pull the build from
    [string]$Asset = "zed-rtl-x86_64.exe",
    [string]$LocalExe = "",                   # use a local build instead of downloading
    [switch]$Revert,
    [switch]$DisableAutoUpdate,
    [switch]$VerifyOnly,
    [switch]$Force,
    [switch]$Silent
)
$ErrorActionPreference = "Stop"
$Repo = "amiralimanzar/zed-rtl"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-InstalledZed {
    if ($ZedExe) { return $ZedExe }
    return Join-Path $env:LOCALAPPDATA "\Programs\Zed\Zed.exe"
}

function Stop-ZedIfRunning {
    $procs = Get-Process -Name "zed" -ErrorAction SilentlyContinue
    if ($procs) {
        if (-not ($Force -or $Silent)) {
            Write-Warning "Zed is running and will be force-closed. Unsaved changes could be lost."
            Read-Host "Press Enter to continue, or Ctrl+C to abort"
        }
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------------------ REVERT
if ($Revert) {
    $zed = Get-InstalledZed
    $bak = "$zed.bak"
    if (-not (Test-Path $bak)) { Write-Error "No backup found at $bak - nothing to revert."; exit 1 }
    Stop-ZedIfRunning
    Move-Item $bak $zed -Force
    $settings = Join-Path $env:APPDATA "Zed\settings.json.zedrtl-bak"
    if (Test-Path $settings) {
        Move-Item $settings (Join-Path $env:APPDATA "Zed\settings.json") -Force
        Write-Host "Restored settings.json from backup."
    }
    Write-Host "Reverted to the original Zed. RTL fix is removed."
    exit 0
}

# ------------------------------------------------------------------ detect
$Zed = Get-InstalledZed
if (-not (Test-Path $Zed)) {
    Write-Error "Installed Zed not found at $Zed`nPass -ZedExe <full path to Zed.exe>."
    exit 1
}

$tmp = Join-Path $env:TEMP "zed-rtl-patcher"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$downloaded = Join-Path $tmp $Asset

if ($LocalExe) {
    if (-not (Test-Path $LocalExe)) { Write-Error "Local build not found: $LocalExe"; exit 1 }
    $src = $LocalExe
    Write-Host "Using local build: $src"
} else {
    $url = "https://github.com/$Repo/releases/download/$Tag/$Asset"
    Write-Host "Downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $downloaded
    # hash-verify against the published .sha256 sidecar
    $sumUrl = "$url.sha256"
    try {
        $sumFile = Join-Path $tmp "$Asset.sha256"
        Invoke-WebRequest -Uri $sumUrl -OutFile $sumFile
        $expected = ((Get-Content $sumFile) -split '\s+')[0]
        $actual = (Get-FileHash $downloaded -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { Write-Error "Hash mismatch - download corrupted or tampered. Aborting."; exit 1 }
        Write-Host "Hash verified OK."
    } catch {
        Write-Warning "Could not verify hash (no .sha256 sidecar?): $_"
    }
    $src = $downloaded
}
if ((Get-Item $src).Length -lt 20MB) { Write-Error "Downloaded file too small - aborting."; exit 1 }

$installedVer = (Get-Item $Zed).VersionInfo.ProductVersion
$srcVer = (Get-Item $src).VersionInfo.ProductVersion
Write-Host "Installed Zed : $Zed  (version: $(if ($installedVer) { $installedVer } else { 'n/a' }))"
Write-Host "Replacement    : $src   (version: $(if ($srcVer) { $srcVer } else { 'dev build' }))"

if ($installedVer -and $srcVer -and ($installedVer -ne $srcVer)) {
    Write-Warning "Version mismatch: replacing $installedVer with $srcVer may be a downgrade."
    Write-Warning "Pick a matching release tag: patch-zed.ps1 -Tag v<x.y.z>"
}

if ($VerifyOnly) {
    $h1 = (Get-FileHash $Zed -Algorithm SHA256).Hash.ToLower()
    $h2 = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    Write-Host ("Installed == patched build: {0}" -f ($h1 -eq $h2))
    exit 0
}

if (-not ($Force -or $Silent)) {
    Read-Host "Press Enter to patch, or Ctrl+C to abort"
}

# ------------------------------------------------------------------ patch
Stop-ZedIfRunning

$bak = "$Zed.bak"
if (-not (Test-Path $bak)) {
    Copy-Item $Zed $bak
    Write-Host "Backed up original to $bak"
} else {
    Write-Host "Backup already exists ($bak) - not overwriting."
}
Copy-Item $src $Zed -Force
Write-Host "Patched $Zed with the RTL build."

# ------------------------------------------------------------------ settings
if ($DisableAutoUpdate) {
    $settings = Join-Path $env:APPDATA "Zed\settings.json"
    if (Test-Path $settings) {
        try {
            $bakS = "$settings.zedrtl-bak"
            if (-not (Test-Path $bakS)) { Copy-Item $settings $bakS }
            $txt = Get-Content $settings -Raw
            if ($txt -match '"auto_update"\s*:\s*(true|false)') {
                $txt = $txt -replace '"auto_update"\s*:\s*(true|false)', '"auto_update": false'
            } else {
                $txt = $txt -replace '^\s*\{', "{`n    `"auto_update`": false,"
            }
            Set-Content -Path $settings -Value $txt -NoNewline
            Write-Host "Set 'auto_update: false' in settings.json (backup at $bakS)."
            Write-Host "Official Zed updates will no longer silently remove the fix."
        } catch {
            Write-Warning "Could not edit settings.json automatically: $_"
            Write-Host "Add this to your settings.json yourself:  `"auto_update`": false"
        }
    } else {
        Write-Host "No settings.json found; create one containing { `"auto_update`": false } to freeze updates."
    }
}

Write-Host ""
Write-Host "Done. If something looks wrong, revert with:  patch-zed.ps1 -Revert"
