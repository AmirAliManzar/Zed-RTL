#requires -Version 5.1
<#
.SYNOPSIS
    Replaces your installed Zed with the RTL-patched build (or reverts).

.DESCRIPTION
    Resolves the release that matches the Zed version you actually have
    installed, downloads it with a progress bar, verifies its SHA-256
    against the published sidecar, and swaps it in (backing up the original).

    A downloaded build is cached under %LOCALAPPDATA%\Zed-RTL\downloads, so
    re-running the patcher after an interrupted download does not start over.

.PARAMETER LocalExe
    Use an already-downloaded build instead of downloading. Also picked up
    automatically if a zed-rtl-*.exe sits next to the patcher exe.

.PARAMETER AllowAny
    Install the latest release even when it was built for a different Zed
    version than the one you have installed. Off by default: silently
    swapping a 1.23.0 install for a 1.22.0 build is exactly the bug this
    flag exists to opt out of.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -NoAutoUpdate
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -LocalExe C:\Downloads\zed-rtl-x86_64.exe
    powershell -ExecutionPolicy Bypass -File patch-zed.ps1 -Revert
#>
[CmdletBinding()]
param(
    [string]$ZedExe = "",
    [string]$Tag = "",                            # auto: resolved from each release's build-info.json
    [string]$Asset = "zed-rtl-x86_64.exe",
    [string]$LocalExe = "",                       # use an already-downloaded build
    [switch]$Revert,
    [switch]$NoAutoUpdate,                         # opt out of freezing Zed's updater AND our task
    [switch]$VerifyOnly,
    [switch]$Force,
    [switch]$Silent,
    [switch]$AllowAny,
    [switch]$UpdateIfAvailable,                    # (internal) check GitHub and update only if newer
    [int]$Retries = 3
)
$ErrorActionPreference = "Stop"
$Repo = "amiralimanzar/zed-rtl"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CacheDir = Join-Path $env:LOCALAPPDATA "Zed-RTL\downloads"

function Get-InstalledZed {
    if ($ZedExe) { return $ZedExe }
    return Join-Path $env:LOCALAPPDATA "\Programs\Zed\Zed.exe"
}

# Release names are our own (v0.0.1, v0.0.2...), not Zed's version, so the
# only reliable way to map an installed Zed to a release is to read the
# build-info json shipped with each release and compare its upstream_ref.
#
# Returns the matching tag, or $null when no release was built for the
# installed Zed version. Callers must handle $null explicitly rather than
# grabbing "latest": a latest that targets a different Zed version would
# silently downgrade the user.
function Resolve-ReleaseTag {
    param([string]$InstalledClean, [string]$Asset, [switch]$AllowAny)
    $arch = if ($Asset -match 'aarch64') { 'aarch64' } else { 'x86_64' }
    $infoName = "build-info-$arch.json"
    $api = "https://api.github.com/repos/$Repo/releases?per_page=100"
    $rels = $null
    try {
        $rels = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 30
    } catch {
        if ($AllowAny) {
            Write-Warning "Could not list releases ($($_.Exception.Message)); using the latest release."
            return "latest"
        }
        return $null
    }
    $wanted = "v$InstalledClean"
    $newer = @()
    $older = $null
    $latest = $rels[0].tag_name
    foreach ($rel in $rels) {
        $info = $rel.assets | Where-Object { $_.name -eq $infoName } | Select-Object -First 1
        if (-not $info) { continue }
        $json = $null
        try { $json = Invoke-RestMethod -Uri $info.browser_download_url -UseBasicParsing -TimeoutSec 30 } catch { continue }
        if ($json.upstream_ref -ne $wanted) {
            # Track whether an older or a newer Zed build exists, for the
            # not-yet-built message below.
            if ($json.upstream_ref -gt $wanted) { $newer += $rel.tag_name }
            elseif (-not $older) { $older = $rel.tag_name }
            continue
        }
        # Wrap in @() so a single match still counts as 1 on PowerShell 5.1.
        $hasAsset = @($rel.assets | Where-Object { $_.name -eq $Asset }).Count -gt 0
        if ($hasAsset) { return $rel.tag_name }
    }
    if ($AllowAny) {
        Write-Warning "No release was built for Zed $InstalledClean; -AllowAny is set, using $latest."
        return $latest
    }
    return $null
}

# SHA-256 the published sidecar advertises for (tag, asset), or $null.
function Get-ExpectedHash {
    param([string]$Tag, [string]$Asset)
    if ($Tag -eq "latest") { return $null }
    try {
        $sum = Invoke-RestMethod -Uri "https://github.com/$Repo/releases/download/$Tag/$Asset.sha256" -UseBasicParsing -TimeoutSec 30
        return ($sum -split '\s+')[0].ToLower()
    } catch { return $null }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$([int64]$Bytes) B"
}

# Downloads with a live progress bar, retrying on network stalls. The
# built-in Invoke-WebRequest prints nothing until the whole 342 MB is on
# disk, which looks indistinguishable from a hang.
function Invoke-DownloadWithProgress {
    param([string]$Url, [string]$Destination, [int]$Retries)

    # Holds the progress the WebClient's background thread reports. A
    # hashtable is used instead of a script variable because the event
    # action runs on a different thread.
    $st = @{ received = 0L; total = 0L; done = $false; err = $null; lastTick = [DateTime]::Now; start = [DateTime]::Now; rateTick = [DateTime]::Now; rateBytes = 0L }

    $attempt = 0
    while ($attempt -lt $Retries) {
        $attempt++
        $script:tmpDest = "$Destination.part"
        if (Test-Path $script:tmpDest) { Remove-Item $script:tmpDest -Force }
        $st['received'] = 0L
        $st['total'] = 0L
        $st['done'] = $false
        $st['err'] = $null
        $st['lastTick'] = [DateTime]::Now
        $st['start'] = [DateTime]::Now

        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "zed-rtl-patcher")
        $progressJob = Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged -SourceIdentifier "DlProgress$attempt" -MessageData $st -Action {
            $d = $Event.MessageData
            $d['received'] = $EventArgs.BytesReceived
            $d['total'] = $EventArgs.TotalBytesToReceive
            $d['lastTick'] = [DateTime]::Now
        }
        $doneJob = Register-ObjectEvent -InputObject $wc -EventName DownloadFileCompleted -SourceIdentifier "DlDone$attempt" -MessageData $st -Action {
            $d = $Event.MessageData
            $d['done'] = $true
            $d['err'] = $EventArgs.Error
        }

        try {
            $wc.DownloadFileAsync([Uri]$Url, $script:tmpDest)
        } catch {
            Unregister-Event -SourceIdentifier "DlProgress$attempt" -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier "DlDone$attempt" -ErrorAction SilentlyContinue
            $wc.Dispose()
            if ($attempt -ge $Retries) { throw }
            Start-Sleep -Seconds 3
            continue
        }

        $lastRender = [DateTime]::Now
        while (-not $st['done']) {
            Start-Sleep -Milliseconds 150
            $now = [DateTime]::Now
            if ((($now - $lastRender).TotalMilliseconds) -ge 250) {
                $lastRender = $now
                $rec = [double]$st['received']
                $tot = [double]$st['total']

                if ($tot -gt 0) {
                    $pct = [Math]::Min(99, [int]($rec / $tot * 100))
                    $barW = 24
                    $filled = [int]($pct / 100 * $barW)
                    $bar = ("#" * $filled) + ("-" * ($barW - $filled))
                    # Rate over the whole download so far, not the last
                    # fraction of a second (which jumps around wildly).
                    $elapsed = ($now - $st['start']).TotalSeconds
                    $rate = if ($elapsed -gt 0.5) { $rec / $elapsed } else { 0 }
                    $eta = if ($rate -gt 1KB) { ($tot - $rec) / $rate } else { 0 }
                    $etaTxt = if ($eta -gt 0) { ("{0:mm\:ss}" -f [TimeSpan]::FromSeconds($eta)) + " left" } else { "?" }
                    $line = "  [$bar] $pct%  $(Format-Bytes $rec) / $(Format-Bytes $tot)  $(if ($rate -gt 1KB) { (Format-Bytes $rate) + '/s' } else { 'starting...' })  $etaTxt"
                } else {
                    $line = "  Connecting... $(Format-Bytes $rec) received"
                }
                Write-Host ("`r{0}" -f $line.PadRight(78)) -NoNewline
            }

            # A connection that stops receiving for 60s is treated as dead.
            if ((($now - $st['lastTick']).TotalSeconds) -gt 60) {
                Write-Host ""
                Write-Warning "Download stalled for over a minute; cancelling (attempt $attempt of $Retries)."
                try { $wc.CancelAsync() } catch {}
                $st['done'] = $true
                $st['err'] = New-Object System.Exception "download stalled"
            }
        }

        Unregister-Event -SourceIdentifier "DlProgress$attempt" -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier "DlDone$attempt" -ErrorAction SilentlyContinue
        $wc.Dispose()

        if ($st['err'] -and $attempt -ge $Retries) {
            Write-Host ""
            throw "Download failed after $Retries attempts: $($st['err'].Message)"
        }
        if (-not $st['err']) {
            Write-Host ""
            Move-Item $script:tmpDest $Destination -Force
            return $true
        }
        Write-Host "  Retrying in 3 seconds..." -NoNewline
        Start-Sleep -Seconds 3
        Write-Host ""
    }
    return $false
}

function Stop-ZedIfRunning {
    $procs = Get-Process -Name "zed" -ErrorAction SilentlyContinue
    if ($procs) {
        if ($DeferIfRunning) {
            # Background auto-update: never force-close the editor and risk
            # losing unsaved work. The build is already downloaded and cached,
            # so the next scheduled run swaps it in once Zed has been closed.
            Write-Output ("{0}: Zed is running; the update is cached and will be installed once Zed is closed." -f (Get-Date -Format "s"))
            exit 0
        }
        if (-not ($Force -or $Silent)) {
            Write-Warning "Zed is running and will be force-closed. Unsaved changes could be lost."
            Read-Host "Press Enter to continue, or Ctrl+C to abort"
        }
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------ auto-updater
# Zed's own auto-updater pulls from zed.dev and would silently replace the
# patched build. We turn that off and instead poll our own releases: the
# scheduled task runs this script with -UpdateIfAvailable, which only swaps
# in a newer release when one exists for the installed Zed version.

$DeferIfRunning = $false

# Bare major.minor.patch compare (-1 / 0 / 1). Splits on . - + so a build
# like "1.23.2+dev.30" or a tag like "v1.24.0" both reduce to three numbers;
# string comparison alone would call 1.10.0 older than 1.9.0.
function Compare-Semver {
    param([string]$A, [string]$B)
    $aa = (($A -replace '^v', '') -split '[\.\-+]')[0..2]
    $bb = (($B -replace '^v', '') -split '[\.\-+]')[0..2]
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; $y = 0
        if ($i -lt $aa.Count) { [int]::TryParse($aa[$i], [ref]$x) | Out-Null }
        if ($i -lt $bb.Count) { [int]::TryParse($bb[$i], [ref]$y) | Out-Null }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

$ZedRtlDir = Join-Path $env:ProgramFiles "Zed-RTL"
$TaskName = "Zed-RTL-AutoUpdate"

function Get-LatestReleaseInfo {
    param([string]$Asset)
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 30
        $arch = if ($Asset -match 'aarch64') { 'aarch64' } else { 'x86_64' }
        $info = $rel.assets | Where-Object { $_.name -eq "build-info-$arch.json" } | Select-Object -First 1
        if ($info) {
            $j = Invoke-RestMethod -Uri $info.browser_download_url -UseBasicParsing -TimeoutSec 30
            return @{ tag = $rel.tag_name; upstream = $j.upstream_ref }
        }
    } catch { }
    return $null
}

function Install-AutoUpdater {
    try {
        New-Item -ItemType Directory -Force -Path $ZedRtlDir | Out-Null
        $scriptCopy = Join-Path $ZedRtlDir "patch-zed.ps1"
        Copy-Item $PSCommandPath $scriptCopy -Force
    } catch {
        Write-Warning "Could not install the auto-updater (need administrator): $($_.Exception.Message)"
        Write-Host "Re-run the patcher as administrator to enable background updates."
        return
    }

    # schtasks.exe strips every double quote from /TR, which turns "C:\Program
    # Files\..." into a broken command; the ScheduledTasks cmdlet keeps them.
    # Output goes through cmd.exe so the log redirect is honoured.
    $log = Join-Path $ZedRtlDir "autoupdate.log"
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -UpdateIfAvailable -Silent -Force' -f $scriptCopy
    $cmd = '/c powershell.exe {0} >> "{1}" 2>&1' -f $psArgs, $log

    $ok = $false
    if (Get-Module -ListAvailable -Name ScheduledTasks) {
        try {
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $cmd
            # -Once with an open-ended repetition is the reliable way to say
            # "every 2 hours, forever" on PowerShell 5.1.
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) `
                -RepetitionInterval (New-TimeSpan -Hours 2) `
                -RepetitionDuration (New-TimeSpan -Days 9999)
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -RunLevel Highest -Settings $settings -Force | Out-Null
            $ok = $true
        } catch {
            Write-Warning "Register-ScheduledTask failed ($($_.Exception.Message)); falling back to schtasks."
        }
    }
    if (-not $ok) {
        schtasks /Create /TN $TaskName /TR "cmd.exe $cmd" /SC HOURLY /MO 2 /RL HIGHEST /F | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    if ($ok) {
        Write-Host "Auto-update installed: a background task checks our GitHub releases every 2 hours."
    } else {
        Write-Warning "Could not create the scheduled task."
    }
}

function Freeze-ZedAutoUpdate {
    $settings = Join-Path $env:APPDATA "Zed\settings.json"
    if (-not (Test-Path $settings)) {
        # No settings file yet: write a minimal one so the freeze sticks.
        try {
            '{ "auto_update": false }' | Set-Content -Path $settings -NoNewline
            Write-Host "Created settings.json with 'auto_update: false'."
        } catch {
            Write-Host "No settings.json found; create one with `"auto_update`": false to freeze updates."
        }
        return
    }
    try {
        $txt = Get-Content $settings -Raw
        if ($txt -match '(?m)^[ \t]*"auto_update"[ \t]*:[ \t]*false') {
            # Already frozen; nothing to write.
            return
        }
        $bakS = "$settings.zedrtl-bak"
        if (-not (Test-Path $bakS)) { Copy-Item $settings $bakS }
        if ($txt -match '(?m)^[ \t]*"auto_update"[ \t]*:[ \t]*true') {
            # Key is there and enabled: flip it in place, leaving the rest of
            # the file (and its comments) untouched.
            $txt = $txt -replace '(?m)(^[ \t]*"auto_update"[ \t]*:[ \t]*)true', '$1false'
        } else {
            # No key yet: insert one right after the object opens. The file
            # starts with // comments, so anchor on the first brace that
            # begins a line rather than on the start of the string.
            $m = [regex]::Match($txt, '(?m)^[ \t]*\{')
            if (-not $m.Success) { throw "could not find the opening brace in settings.json" }
            $at = $m.Index + $m.Length
            $txt = $txt.Substring(0, $at) + "`n    `"auto_update`": false," + $txt.Substring($at)
        }
        Set-Content -Path $settings -Value $txt -NoNewline
        $check = Get-Content $settings -Raw
        if ($check -imatch '(?m)^[ \t]*"auto_update"[ \t]*:[ \t]*false') {
            Write-Host "Set 'auto_update: false' in settings.json (backup at $bakS)."
            Write-Host "Official Zed updates will no longer silently remove the fix."
        } else {
            throw "the write did not produce an auto_update: false entry"
        }
    } catch {
        Write-Warning "Could not edit settings.json automatically: $_"
        Write-Host "Add this to your settings.json yourself:  `"auto_update`": false"
    }
}

# ------------------------------------------------------------- REVERT
if ($Revert) {
    $zed = Get-InstalledZed
    $bak = "$zed.bak"
    if (-not (Test-Path $bak)) { Write-Error "No backup found at $bak - nothing to revert."; exit 1 }
    # Tear down the background updater first, otherwise the scheduled task
    # would re-patch Zed again on its next run.
    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
    $stillThere = $null
    try { $stillThere = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    if ($stillThere) {
        Write-Warning "The auto-update task could not be removed (need administrator)."
        Write-Host "Run the patcher as administrator with -Revert, or delete the scheduled"
        Write-Host "task '$TaskName' by hand, or it will re-patch Zed on its next run."
    }
    if (Test-Path $ZedRtlDir) {
        Remove-Item $ZedRtlDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
# Resolved before anything else: both the auto-update check and the download
# path need to know which Zed.exe is installed.
$Zed = Get-InstalledZed
if (-not (Test-Path $Zed)) {
    Write-Error "Installed Zed not found at $Zed`nPass -ZedExe <full path to Zed.exe>."
    exit 1
}

# ------------------------------------------------- UpdateIfAvailable mode
# Invoked by the scheduled task. Behaves like a normal silent run, except:
#   - a newer Zed release than the one installed triggers an upgrade,
#   - an older/missing build is not an error, and
#   - Zed is never force-closed to make the swap happen.
if ($UpdateIfAvailable) {
    $Silent = $true
    $Force = $true
    $DeferIfRunning = $true
    $installedProduct = (Get-Item $Zed).VersionInfo.ProductVersion
    $clean = if ($installedProduct) { ($installedProduct -split '\+')[0] } else { "" }
    if ($clean) {
        $latest = Get-LatestReleaseInfo -Asset $Asset
        if (-not $latest) {
            Write-Output ("{0}: could not reach GitHub to check for updates." -f (Get-Date -Format "s"))
            exit 0
        }
        $cmp = Compare-Semver $latest.upstream $clean
        if ($cmp -lt 0) {
            # Our newest build targets an older Zed than the installed one.
            # Wait for CI to publish a matching build instead of downgrading.
            Write-Output ("{0}: installed Zed {1} is newer than our latest build ({2}) - waiting for a matching release." -f (Get-Date -Format "s"), $clean, $latest.upstream)
            exit 0
        }
        if ($cmp -gt 0) {
            Write-Output ("{0}: upgrading Zed {1} to {2} (release {3})." -f (Get-Date -Format "s"), $clean, $latest.upstream, $latest.tag)
            $Tag = $latest.tag
        }
        # $cmp -eq 0: fall through. The normal path patches an unpatched
        # install and exits 0 when the RTL build is already in place.
    }
}

$tmp = Join-Path $env:TEMP "zed-rtl-patcher"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$downloaded = Join-Path $CacheDir $Asset

# The installed version is needed both to sanity-check a -LocalExe file and
# to pick the release, so resolve it before branching on either path.
$installedProduct = (Get-Item $Zed).VersionInfo.ProductVersion
$clean = if ($installedProduct) { ($installedProduct -split '\+')[0] } else { "" }
if ($installedProduct) {
    Write-Host "Installed Zed is $installedProduct -> looking for a release built for Zed $clean"
}

if ($LocalExe) {
    if (-not (Test-Path $LocalExe)) { Write-Error "Local build not found: $LocalExe"; exit 1 }
    # A file the user hands us is only usable if it targets the Zed they have.
    # When it does not, ignore it and fall through to the download path rather
    # than aborting: a stale downloaded file sitting next to the patcher must
    # never block patching a freshly updated Zed.
    $lv = (Get-Item $LocalExe).VersionInfo.ProductVersion
    $lclean = if ($lv) { ($lv -split '\+')[0] } else { "" }
    if ($lv -and $clean -and ($lclean -ne $clean)) {
        Write-Warning "The local file is for Zed $lclean, but you have $clean installed - ignoring it and downloading the matching build."
        $LocalExe = ""
    } else {
        $src = $LocalExe
        Write-Host "Using local build: $src"
    }
}

if (-not $LocalExe) {
    if (-not $Tag) {
        if (-not $clean) {
            Write-Warning "Could not read the installed Zed version; defaulting to the latest release."
            $Tag = "latest"
        } else {
            $Tag = Resolve-ReleaseTag -InstalledClean $clean -Asset $Asset -AllowAny:$AllowAny
            if (-not $Tag) {
                # This is the path that used to silently grab "latest" and
                # downgrade a newer Zed. Say clearly what happened instead.
                Write-Host ""
                Write-Host "No RTL build for Zed $clean has been published yet." -ForegroundColor Yellow
                Write-Host "The tracker workflow checks for a new Zed release every 2 hours and"
                Write-Host "publishes a matching build automatically, so this usually resolves"
                Write-Host "itself within a few hours of the upstream release."
                Write-Host ""
                Write-Host "Options:"
                Write-Host "  - Wait a few hours and run the patcher again."
                Write-Host "  - Use a build you already have:  -LocalExe C:\path\to\zed-rtl.exe"
                Write-Host "  - Force the latest build anyway: -AllowAny"
                Write-Host "    (this may replace a newer Zed with an older one)"
                exit 2
            }
            Write-Host "Using release tag: $Tag"
        }
    }

    $url = "https://github.com/$Repo/releases/download/$Tag/$Asset"
    $expected = Get-ExpectedHash -Tag $Tag -Asset $Asset

    # If the installed binary already is this exact build, stop here. Without
    # this check, re-running the patcher would spend ~25 minutes downloading
    # 342 MB only to arrive at the file that is already in place.
    if ($expected) {
        try {
            $hInstalled = (Get-FileHash $Zed -Algorithm SHA256).Hash.ToLower()
            if ($hInstalled -eq $expected) {
                Write-Host "Zed is already the RTL build for this release - nothing to do."
                Write-Host "To undo the patch, run again with -Revert."
                # An install patched before the auto-updater existed still needs
                # its updates frozen and the background task installed. Skip the
                # task refresh in scheduled runs so it does not rewrite itself
                # every two hours; the freeze is cheap and idempotent.
                if (-not $NoAutoUpdate) {
                    Freeze-ZedAutoUpdate
                    if (-not $UpdateIfAvailable) { Install-AutoUpdater }
                }
                exit 0
            }
        } catch { }
    }

    # Reuse a cached download whose hash still matches, so an interrupted
    # session or a second run never re-downloads 342 MB.
    if ((Test-Path $downloaded) -and $expected) {
        $have = (Get-FileHash $downloaded -Algorithm SHA256).Hash.ToLower()
        if ($have -eq $expected) {
            Write-Host "Using the previously downloaded build (verified): $downloaded"
            $src = $downloaded
        } else {
            Write-Host "Cached build is out of date; downloading again."
            Remove-Item $downloaded -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $src) {
        Write-Host "Downloading $url"
        Write-Host "(this is a full Zed build; on a slow link it can take a while)"
        Invoke-DownloadWithProgress -Url $url -Destination $downloaded -Retries $Retries | Out-Null

        if ($expected) {
            $actual = (Get-FileHash $downloaded -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item $downloaded -Force -ErrorAction SilentlyContinue
                Write-Error "Hash mismatch - download corrupted or tampered. Aborting."
                exit 1
            }
            Write-Host "SHA-256 verified OK."
        } else {
            Write-Warning "Could not verify hash (no .sha256 sidecar for this asset)."
        }
        $src = $downloaded
    }
}
if ((Get-Item $src).Length -lt 20MB) { Write-Error "Replacement file too small ($((Get-Item $src).Length) bytes) - aborting."; exit 1 }

$installedVer = (Get-Item $Zed).VersionInfo.ProductVersion
$srcVer = (Get-Item $src).VersionInfo.ProductVersion
Write-Host "Installed Zed : $Zed  (version: $(if ($installedVer) { $installedVer } else { 'n/a' }))"
Write-Host "Replacement    : $src   (version: $(if ($srcVer) { $srcVer } else { 'dev build' }))"

if ($installedVer -and $srcVer) {
    $iv = ($installedVer -split '\+')[0]
    $sv = ($srcVer -split '\+')[0]
    if ($iv -ne $sv) {
        Write-Warning "Version mismatch: installed $iv vs build $sv. Refusing to swap them."
        Write-Host "Run with -AllowAny to do it anyway, or pick a build for $iv."
        if (-not $AllowAny) { exit 3 }
    }
}

if ($VerifyOnly) {
    $h1 = (Get-FileHash $Zed -Algorithm SHA256).Hash.ToLower()
    $h2 = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    Write-Host ("Installed == patched build: {0}" -f ($h1 -eq $h2))
    exit 0
}

if (-not ($Force -or $Silent)) {
    Write-Host ""
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
# Freeze Zed's own updater and stand up our background one. Reached both after
# a fresh patch and - via the early exit above - when the RTL build is already
# in place, since an install patched by an older patcher never had this done.
if (-not $NoAutoUpdate) {
    Freeze-ZedAutoUpdate
    # Install the background task that pulls our releases instead.
    Install-AutoUpdater
} else {
    # The user opted out; remove any task a previous run created.
    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
}

Write-Host ""
if (-not $NoAutoUpdate) {
    Write-Host "Done. Zed now updates from github.com/$Repo instead of zed.dev."
} else {
    Write-Host "Done. Auto-update was left disabled."
}
Write-Host "If something looks wrong, revert with:  patch-zed.ps1 -Revert"
