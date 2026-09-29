#requires -Version 5.1
<#
.SYNOPSIS
    Local convenience: build patched Zed, then optionally deploy it to your
    installed Zed. Thin wrapper around build.patched.ps1 + patch-zed.ps1.
.EXAMPLE
    .\build-and-deploy.ps1                    # build only
    .\build-and-deploy.ps1 -Deploy            # build + replace installed Zed
    .\build-and-deploy.ps1 -Deploy -Silent    # ... non-interactive
#>
[CmdletBinding()]
param(
    [string]$UpstreamRef = "",
    [string]$Proxy = $env:HTTP_PROXY,
    [switch]$Deploy,
    [switch]$Silent,
    [switch]$NoStrip
)
$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

$buildArgs = @($PSScriptRoot + "\build.patched.ps1")
if ($UpstreamRef) { $buildArgs += "-UpstreamRef", $UpstreamRef }
if ($Proxy) { $buildArgs += "-Proxy", $Proxy }
if ($NoStrip) { $buildArgs += "-NoStrip" }
& Powershell -ExecutionPolicy Bypass -File @buildArgs
if ($LASTEXITCODE -ne 0) { throw "build failed" }

if ($Deploy) {
    $exe = Join-Path $repoRoot "artifacts\zed-rtl-x86_64.exe"
    $patchArgs = @($PSScriptRoot + "\patch-zed.ps1", "-LocalExe", $exe)
    if ($Silent) { $patchArgs += "-Silent" }
    & Powershell -ExecutionPolicy Bypass -File @patchArgs
}
