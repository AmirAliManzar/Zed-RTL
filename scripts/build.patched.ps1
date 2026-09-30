#requires -Version 5.1
<#
.SYNOPSIS
    Builds the RTL-patched Zed for Windows (shared by CI and local runs).
.DESCRIPTION
    Clones upstream Zed at the pinned commit (UPSTREAM_REF), applies
    patch/zed-rtl.patch, compiles a release zed.exe, strips debug symbols,
    and stages the artifact(s) in the artifacts/ folder next to this repo.
#>
[CmdletBinding()]
param(
    [string]$UpstreamRef = "",
    [string]$Target = "x86_64-pc-windows-msvc",
    [string]$ArtifactName = "",
    [string]$WorkDir = "",
    [string]$OutDir = "",
    [string]$Proxy = $env:HTTP_PROXY,
    [switch]$NoStrip
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$patchPath = Join-Path $repoRoot "patch\zed-rtl.patch"

# Default artifact name matches the build target.
if (-not $ArtifactName) {
    $ArtifactName = if ($Target -like "aarch64*") { "zed-rtl-aarch64.exe" } else { "zed-rtl-x86_64.exe" }
}

# Host triple (the machine running the build). The toolchain is installed for
# the host, then the cross target is layered on top of it.
$hostTriple = "x86_64-pc-windows-msvc"
try {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq "Arm64") {
        $hostTriple = "aarch64-pc-windows-msvc"
    }
} catch { }

if (-not $UpstreamRef) {
    $UpstreamRef = (Get-Content (Join-Path $repoRoot "UPSTREAM_REF") -Raw).Trim()
}
Write-Host "== Zed-RTL build =="
Write-Host "Upstream ref: $UpstreamRef"

if ($Proxy) {
    $env:HTTP_PROXY = $Proxy
    $env:HTTPS_PROXY = $Proxy
}

# ---------------------------------------------------------------- toolchain
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    $localCmake = "C:\tools2\cmake-3.28.4-windows-x86_64\bin"
    if (Test-Path $localCmake) { $env:PATH = "$localCmake;$env:PATH" }
}
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    $rustupArch = if ($hostTriple -like "aarch64*") { "aarch64" } else { "x86_64" }
    Invoke-WebRequest -Uri "https://win.rustup.rs/$rustupArch" -OutFile "rustup-init.exe"
    & ".\rustup-init.exe" -y --default-toolchain none --profile minimal
    $env:PATH += ";$env:USERPROFILE\.cargo\bin"
}

# ---------------------------------------------------------------- source
if (-not $WorkDir) {
    if ($env:RUNNER_TEMP) { $WorkDir = Join-Path $env:RUNNER_TEMP "zed-rtl-build" }
    else { $WorkDir = Join-Path $env:TEMP "zed-rtl-build" }
}
$srcDir = Join-Path $WorkDir "zed"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

if (-not (Test-Path (Join-Path $srcDir ".git"))) {
    Write-Host "Cloning upstream (blobless)..."
    git clone --filter=blob:none --no-checkout --quiet https://github.com/zed-industries/zed.git $srcDir
}
Push-Location $srcDir
git fetch --quiet --depth=1 origin $UpstreamRef
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "git fetch failed for ref $UpstreamRef" }
git checkout --force --quiet $UpstreamRef
# no-op for refs without submodules; protects future UPSTREAM_REF bumps
git submodule update --init --recursive --quiet
Pop-Location

# Toolchain: honor the channel pinned by upstream's rust-toolchain.toml so
# the build works for any UPSTREAM_REF (1.95.0 on old refs, 1.98.1 on v1.21.0, ...).
$channel = "1.95.0"
$tcFile = Join-Path $srcDir "rust-toolchain.toml"
$m = Select-String -Path $tcFile -Pattern '^\s*channel\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($m) { $channel = $m.Matches[0].Groups[1].Value }
Write-Host "Toolchain from upstream rust-toolchain.toml: $channel"
rustup toolchain install $channel --profile minimal
$env:RUSTUP_TOOLCHAIN = "$channel-$hostTriple"
if ($Target -ne $hostTriple) {
    rustup target add $Target --toolchain "$channel-$hostTriple"
}
Write-Host "Rust: $(cargo --version)"
Write-Host "Build target: $Target"

# ---------------------------------------------------------------- patch
Write-Host "Applying patch..."
git -C $srcDir apply --check $patchPath
if ($LASTEXITCODE -ne 0) {
    throw @"
PATCH CONFLICT: patch/zed-rtl.patch does not apply to upstream $UpstreamRef.
The upstream file crates/gpui_windows/src/direct_write.rs has changed.
Refresh the patch: re-clone at the new ref and re-apply the changes
(see docs/TECHNICAL.md), then update UPSTREAM_REF.
"@
}
git -C $srcDir apply --verbose $patchPath
if ($LASTEXITCODE -ne 0) { throw "git apply failed" }

# ------------------------------------------------------- spectre workaround
# The Rust `windows` crate links MSVC's Spectre-mitigated libs, but the
# "Spectre-mitigated libraries" VS component is often not installed.
# If lib\spectre\<arch> is missing, junction it to lib\<arch>.
$archDir = if ($Target -like "aarch64*") { "arm64" } else { "x64" }
$vsBases = @(
    "C:\Program Files\Microsoft Visual Studio\2022",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022",
    "C:\Program\Microsoft Visual Studio\2022",
    "C:\Program\VC"
) | Where-Object { Test-Path $_ }
foreach ($base in $vsBases) {
    $msvcDir = Join-Path $base "VC\Tools\MSVC"
    if (-not (Test-Path $msvcDir)) { continue }
    $latest = Get-ChildItem $msvcDir -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { continue }
    # handles both standard (tools\ver\lib) and rare flat (lib) layouts
    $libRoots = @((Join-Path $latest.FullName "lib"), (Join-Path $msvcDir "lib"))
    foreach ($libRoot in ($libRoots | Where-Object { Test-Path (Join-Path $_ $archDir) })) {
        $spectre = Join-Path $libRoot "spectre\$archDir"
        $archLib = Join-Path $libRoot $archDir
        if (-not (Test-Path $spectre) -and (Test-Path $archLib)) {
            Write-Host "Spectre libs missing -> junction $spectre -> $archLib"
            New-Item -ItemType Junction -Path $spectre -Target $archLib -Force | Out-Null
        }
    }
}

# ---------------------------------------------------------------- build
Write-Host "Building (release, $Target) - this takes a while..."
Push-Location $srcDir
cargo build --release --target $Target -p zed
$buildOk = $LASTEXITCODE -eq 0
Pop-Location
if (-not $buildOk) { throw "cargo build failed" }

$exe = Join-Path $srcDir "target\$Target\release\zed.exe"
if (-not (Test-Path $exe)) { throw "expected build output not found: $exe" }
$sizeMB = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "Built zed.exe ($sizeMB MB)"

# ---------------------------------------------------------------- strip
if (-not $NoStrip) {
    try {
        rustup component add llvm-tools 2>$null | Out-Null
        $strip = Get-ChildItem -Path "$env:USERPROFILE\.rustup" -Recurse -Filter "llvm-strip.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($strip) {
            & $strip.FullName --strip-debug $exe
            Write-Host "Stripped debug symbols -> $([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB"
        } else {
            Write-Warning "llvm-strip not found; keeping debug symbols"
        }
    } catch {
        Write-Warning "strip step failed (non-fatal): $_"
    }
}

# ---------------------------------------------------------------- stage
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "artifacts" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outExe = Join-Path $OutDir $ArtifactName
Copy-Item $exe $outExe -Force

$hash = (Get-FileHash $outExe -Algorithm SHA256).Hash.ToLower()
"$hash  $ArtifactName" | Set-Content (Join-Path $OutDir "$ArtifactName.sha256") -NoNewline
@{
    artifact          = $ArtifactName
    upstream_ref      = $UpstreamRef
    built_at          = (Get-Date -Format "o")
    sha256            = $hash
    size_bytes        = (Get-Item $outExe).Length
    toolchain         = "$channel-$hostTriple"
    target            = $Target
} | ConvertTo-Json | Set-Content (Join-Path $OutDir "build-info.json")

Write-Host "DONE. Artifact: $outExe"
Write-Host "SHA256: $hash"
