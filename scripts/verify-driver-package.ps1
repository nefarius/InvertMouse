[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "ARM64")]
    [string]$Architecture
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Find-WdkTools.ps1")

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$sys = Join-Path $PackageDir "InvertMouse.sys"
$inf = Join-Path $PackageDir "InvertMouse.inf"
$pdb = Join-Path $PackageDir "InvertMouse.pdb"

Assert-True (Test-Path $sys) "Missing InvertMouse.sys in $PackageDir"
Assert-True (Test-Path $inf) "Missing InvertMouse.inf in $PackageDir"

$infText = Get-Content -Path $inf -Raw
Assert-True ($infText -notmatch "HID_DEVICE_SYSTEM_MOUSE") "INF still binds HID_DEVICE_SYSTEM_MOUSE"
Assert-True ($infText -match "DefaultInstall") "INF is missing DefaultInstall"
Assert-True ($infText -match "KmdfService") "INF is missing KMDF directives"
Assert-True ($infText -match "CatalogFile") "INF is missing CatalogFile"
Assert-True ($infText -match "PnpLockdown") "INF is missing PnpLockdown"
Assert-True ($infText -notmatch "UpperFilters") "INF must not set class/device UpperFilters; the installer prepends InvertMouse"

$expectedDecoration = if ($Architecture -eq "x64") { "NTamd64" } else { "NTarm64" }
Assert-True ($infText -match [regex]::Escape($expectedDecoration)) "INF is missing $expectedDecoration decoration"

$bytes = [System.IO.File]::ReadAllBytes($sys)
Assert-True ($bytes.Length -gt 0x40 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) "SYS is not a PE image"
$lfanew = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $lfanew + 4)
$expectedMachine = if ($Architecture -eq "x64") { [uint16]0x8664 } else { [uint16]0xAA64 }
Assert-True ($machine -eq $expectedMachine) ("SYS machine 0x{0:X} does not match {1}" -f $machine, $Architecture)

$infVerif = Get-KitTool -Name "infverif.exe"
if ($infVerif) {
    Write-Host "Running InfVerif /u /v"
    & $infVerif /u /v $inf
    if ($LASTEXITCODE -ne 0) {
        throw "InfVerif failed with exit code $LASTEXITCODE"
    }
}
else {
    Write-Warning "InfVerif.exe was not found; skipped INF validation"
}

if (Test-Path $pdb) {
    Write-Host "PDB present: $pdb"
}
else {
    Write-Warning "InvertMouse.pdb is not in the package directory"
}

Write-Host "Driver package checks passed for $Architecture"
