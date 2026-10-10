#Requires -Version 5.1
<#
.SYNOPSIS
    Rebuilds InvertMouse Release x64 and ARM64 from a clean tree, checks
    freshness, stages Partner Center CABs, and optionally EV-signs the
    binaries and CABs.

.PARAMETER Version
    Optional four-part version stamped into version.h and InvertMouse.inx.

.PARAMETER CertificateSubject
    Subject used with signtool /n. Ignored when CertificateThumbprint is set.

.PARAMETER CertificateThumbprint
    Optional SHA-1 thumbprint used with signtool /sha1 instead of /n.

.PARAMETER TimestampUrl
    RFC 3161 timestamp URL. Default: http://timestamp.digicert.com

.PARAMETER Platforms
    Architectures to build. Default: x64, ARM64.

.PARAMETER SkipSigning
    Rebuild and pack unsigned CABs after stripping any test signature.
    Use this when the EV certificate is not available.

.PARAMETER SignToolPath
    Explicit path to signtool.exe. When omitted, Nefarius.Tools.WDKWhere is
    used (`dotnet wdkwhere run signtool ...`).
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$CertificateSubject,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string[]]$Platforms = @('x64', 'ARM64'),
    [switch]$SkipSigning,
    [string]$SignToolPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SigningHelpers.ps1')

if ($Platforms.Count -eq 1 -and $Platforms[0] -match ',') {
    $Platforms = @($Platforms[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$Platforms = @($Platforms | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
$SupportedPlatforms = @('x64', 'ARM64')
if ($Platforms.Count -eq 0) {
    throw 'No platforms specified. Supported: x64, ARM64'
}
foreach ($platform in $Platforms) {
    if ($SupportedPlatforms -notcontains $platform) {
        throw ("Unsupported platform '{0}'. Supported: {1}" -f $platform, ($SupportedPlatforms -join ', '))
    }
}

if (-not $SkipSigning) {
    Assert-SigningIdentity -CertificateSubject $CertificateSubject -CertificateThumbprint $CertificateThumbprint
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ArtifactsDir = Join-Path $RepoRoot 'artifacts'
$Solution = Join-Path $RepoRoot 'src\InvertMouseDriver\InvertMouseDriver.sln'
$DriverDir = Join-Path $RepoRoot 'src\InvertMouseDriver'

function Set-DriverVersion {
    param([Parameter(Mandatory)][string]$Version)

    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Version must be four-part, for example 1.0.1.0: $Version"
    }

    $parts = $Version.Split('.')
    $versionH = Join-Path $DriverDir 'version.h'
    $text = Get-Content -LiteralPath $versionH -Raw
    $text = $text -replace '(?m)^(#define VERSION_MAJOR\s+)\d+', ('${1}' + $parts[0])
    $text = $text -replace '(?m)^(#define VERSION_MINOR\s+)\d+', ('${1}' + $parts[1])
    $text = $text -replace '(?m)^(#define VERSION_PATCH\s+)\d+', ('${1}' + $parts[2])
    $text = $text -replace '(?m)^(#define VERSION_BUILD\s+)\d+', ('${1}' + $parts[3])
    [System.IO.File]::WriteAllText($versionH, $text.TrimEnd() + [Environment]::NewLine)

    $inx = Join-Path $DriverDir 'InvertMouse.inx'
    $driverVer = '{0},{1}' -f (Get-Date -Format 'MM/dd/yyyy'), $Version
    $inxText = Get-Content -LiteralPath $inx -Raw
    $inxText = $inxText -replace '(?m)^(DriverVer\s*=\s*).+$', ('${1}' + $driverVer)
    [System.IO.File]::WriteAllText($inx, $inxText.TrimEnd() + [Environment]::NewLine)

    Write-Host ("    version.h and InvertMouse.inx stamped to {0}" -f $Version)
}

Write-Step 'Cleaning previous outputs'
foreach ($dir in @(
        (Join-Path $DriverDir 'x64'),
        (Join-Path $DriverDir 'ARM64'),
        $ArtifactsDir
    )) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null

Write-Step 'Restoring local dotnet tools'
Push-Location $RepoRoot
try {
    Invoke-Native -FilePath 'dotnet' -ArgumentList @('tool', 'restore')
    Initialize-WdkPath -RepoRoot $RepoRoot
}
finally {
    Pop-Location
}

if ($Version) {
    Write-Step ("Stamping version {0}" -f $Version)
    Set-DriverVersion -Version $Version
}

$msbuild = Get-MsBuildPath
Write-Host ("    MSBuild: {0}" -f $msbuild)

foreach ($platform in $Platforms) {
    Write-Step ("Rebuilding Release|{0}" -f $platform)
    Invoke-Native -FilePath $msbuild -ArgumentList @(
        $Solution,
        '-t:Rebuild',
        '-p:Configuration=Release',
        ("-p:Platform={0}" -f $platform),
        '-p:SkipPackageVerification=true',
        '-p:ApiValidator_Enable=false',
        '-m',
        '-v:m',
        '-nologo'
    )
}

Write-Step 'Checking build freshness'
& (Join-Path $PSScriptRoot 'Test-BuildFreshness.ps1') -Configuration Release -Platforms $Platforms
if ($LASTEXITCODE) {
    throw ("Test-BuildFreshness.ps1 exited with code {0}" -f $LASTEXITCODE)
}

$sysFiles = @()
foreach ($platform in $Platforms) {
    $sys = Join-Path $DriverDir ("{0}\Release\InvertMouse.sys" -f $platform)
    if (-not (Test-Path -LiteralPath $sys)) {
        throw "InvertMouse.sys not found for $platform"
    }
    $sysFiles += $sys
}

Write-Step 'Stripping existing signatures'
foreach ($file in $sysFiles) {
    Remove-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath
}

if (-not $SkipSigning) {
    Write-Step 'Signing driver binaries'
    foreach ($file in $sysFiles) {
        Add-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath `
            -CertificateSubject $CertificateSubject -CertificateThumbprint $CertificateThumbprint `
            -TimestampUrl $TimestampUrl
        Confirm-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath
    }
}
else {
    Write-Step 'SkipSigning: binaries left unsigned after strip'
}

$cabs = @()
foreach ($platform in $Platforms) {
    $buildDir = Join-Path $DriverDir ("{0}\Release\InvertMouse" -f $platform)
    $stageDir = Join-Path $ArtifactsDir $platform
    Write-Step ("Staging {0} package" -f $platform)
    & (Join-Path $PSScriptRoot 'stage-driver-package.ps1') -BuildDir $buildDir -Architecture $platform -OutputDir $stageDir
    if ($LASTEXITCODE) {
        throw ("stage-driver-package.ps1 exited with code {0}" -f $LASTEXITCODE)
    }

    $cab = Join-Path $stageDir ("InvertMouseDriver_{0}.cab" -f $platform)
    if (-not (Test-Path -LiteralPath $cab)) {
        throw "CAB was not created: $cab"
    }
    $cabs += $cab
}

if (-not $SkipSigning) {
    Write-Step 'Signing submission CABs'
    foreach ($cab in $cabs) {
        Add-EmbeddedSignature -RepoRoot $RepoRoot -Path $cab -SignToolPath $SignToolPath `
            -CertificateSubject $CertificateSubject -CertificateThumbprint $CertificateThumbprint `
            -TimestampUrl $TimestampUrl
        Confirm-EmbeddedSignature -RepoRoot $RepoRoot -Path $cab -SignToolPath $SignToolPath
    }
}

Write-Step 'Artifacts'
foreach ($cab in $cabs) {
    $hash = (Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash
    $item = Get-Item -LiteralPath $cab
    Write-Host ("    {0}  {1} bytes  SHA256={2}" -f $item.Name, $item.Length, $hash)
}

Write-Host 'Done.'
