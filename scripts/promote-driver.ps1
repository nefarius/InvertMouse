[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",

    [ValidateSet("x64", "ARM64")]
    [string]$Platform = "x64",

    [string]$SourceDir
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SourceDir) {
    # Same package-directory SYS that Build-Release.ps1 signs before staging the CAB.
    $SourceDir = Join-Path $repoRoot "src\InvertMouseDriver\$Platform\$Configuration\InvertMouse"
}

$sys = Join-Path $SourceDir "InvertMouse.sys"
if (-not (Test-Path $sys)) {
    throw "Built driver not found: $sys"
}

& (Join-Path $PSScriptRoot "verify-driver-package.ps1") -PackageDir $SourceDir -Architecture $Platform

$destination = Join-Path $repoRoot "src\DriverInstaller\driver\$Platform"
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -Path $sys -Destination (Join-Path $destination "InvertMouse.sys") -Force

Write-Host "Promoted $sys -> $destination"
Write-Host "Commit the promoted SYS only after it has been validated and, for release, production-signed."
