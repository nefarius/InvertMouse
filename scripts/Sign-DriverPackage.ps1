#Requires -Version 5.1
<#
.SYNOPSIS
    Strips any existing signature, EV-signs driver binaries and submission CABs,
    and verifies the Authenticode signature.

.PARAMETER Path
    A .sys/.cab file, or a directory containing them (default: artifacts\).

.PARAMETER CertificateSubject
    Subject used with signtool /n. Ignored when CertificateThumbprint is set.

.PARAMETER CertificateThumbprint
    Optional SHA-1 thumbprint used with signtool /sha1 instead of /n.

.PARAMETER TimestampUrl
    RFC 3161 timestamp URL. Default: http://timestamp.digicert.com

.PARAMETER SignToolPath
    Explicit path to signtool.exe. When omitted, Nefarius.Tools.WDKWhere is
    used (`dotnet wdkwhere run signtool ...`).
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$CertificateSubject,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$SignToolPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SigningHelpers.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Assert-SigningIdentity -CertificateSubject $CertificateSubject -CertificateThumbprint $CertificateThumbprint

if (-not $Path) {
    $Path = Join-Path $RepoRoot 'artifacts'
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path not found: $Path"
}

$targets = @()
$item = Get-Item -LiteralPath $Path
if ($item.PSIsContainer) {
    $targets = @(Get-ChildItem -LiteralPath $Path -Recurse -File |
        Where-Object { $_.Extension -in '.sys', '.cab' -and $_.DirectoryName -notmatch '\\cab$' } |
        Select-Object -ExpandProperty FullName)
}
else {
    if ($item.Extension -notin '.sys', '.cab') {
        throw "Unsupported file type: $($item.Extension). Expected .sys or .cab"
    }
    $targets = @($item.FullName)
}

if ($targets.Count -eq 0) {
    throw "No .sys or .cab files found under $Path"
}

Push-Location $RepoRoot
try {
    Invoke-Native -FilePath 'dotnet' -ArgumentList @('tool', 'restore')
}
finally {
    Pop-Location
}

Write-Step 'Stripping existing signatures'
foreach ($file in $targets) {
    Remove-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath
}

Write-Step 'Signing'
foreach ($file in $targets) {
    Add-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath `
        -CertificateSubject $CertificateSubject -CertificateThumbprint $CertificateThumbprint `
        -TimestampUrl $TimestampUrl
    Confirm-EmbeddedSignature -RepoRoot $RepoRoot -Path $file -SignToolPath $SignToolPath
}

Write-Host 'Signing complete.'
