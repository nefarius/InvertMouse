#Requires -Version 5.1
<#
.SYNOPSIS
    Fails if Release driver outputs are missing or older than the driver sources.

.DESCRIPTION
    Prevents signing or promoting a stale WDK test-signed binary. Compares the
    newest InvertMouseDriver source timestamp to SYS, PDB, and stamped INF
    outputs for each requested architecture.
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [string[]]$Platforms = @('x64', 'ARM64')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Platforms.Count -eq 1 -and $Platforms[0] -match ',') {
    $Platforms = @($Platforms[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$DriverDir = Join-Path $RepoRoot 'src\InvertMouseDriver'

$sources = Get-ChildItem -LiteralPath $DriverDir -File |
    Where-Object { $_.Extension -in '.cpp', '.h', '.inx', '.rc', '.vcxproj' }
if (-not $sources) {
    throw "No driver sources found in $DriverDir"
}

$newestSource = $sources | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
Write-Host ("Newest source: {0} ({1:o})" -f $newestSource.Name, $newestSource.LastWriteTimeUtc)

foreach ($platform in $Platforms) {
    $outDir = Join-Path $DriverDir ("{0}\{1}" -f $platform, $Configuration)
    $packageDir = Join-Path $outDir 'InvertMouse'
    $required = @(
        (Join-Path $outDir 'InvertMouse.sys'),
        (Join-Path $outDir 'InvertMouse.pdb'),
        (Join-Path $packageDir 'InvertMouse.sys'),
        (Join-Path $packageDir 'InvertMouse.inf')
    )

    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw ("Missing {0} output: {1}" -f $platform, $path)
        }

        $item = Get-Item -LiteralPath $path
        # Stampinf writes the INF before cl.exe finishes, so only binaries
        # must be newer than sources.
        if ($item.Extension -ne '.inf' -and $item.LastWriteTimeUtc -lt $newestSource.LastWriteTimeUtc) {
            throw ("Stale {0} output {1} ({2:o}) is older than {3} ({4:o})" -f `
                    $platform, $item.Name, $item.LastWriteTimeUtc, $newestSource.Name, $newestSource.LastWriteTimeUtc)
        }

        Write-Host ("    {0}: {1} ({2:o})" -f $(if ($item.Extension -eq '.inf') { 'present' } else { 'fresh' }), $item.FullName, $item.LastWriteTimeUtc)
    }
}

Write-Host 'Build freshness check passed.'
