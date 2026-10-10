[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "ARM64")]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"
$BuildDir = (Resolve-Path $BuildDir).Path
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path (Get-Location) $OutputDir
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

if (Test-Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDir | Out-Null

$names = @("InvertMouse.sys", "InvertMouse.inf", "InvertMouse.pdb")
$searchDirs = @($BuildDir, (Split-Path -Parent $BuildDir))
foreach ($name in $names) {
    foreach ($dir in $searchDirs) {
        $source = Join-Path $dir $name
        if (Test-Path $source) {
            Copy-Item -Path $source -Destination (Join-Path $OutputDir $name) -Force
            break
        }
    }
}

& (Join-Path $PSScriptRoot "verify-driver-package.ps1") -PackageDir $OutputDir -Architecture $Architecture

$required = @("InvertMouse.sys", "InvertMouse.inf")
foreach ($name in $required) {
    if (-not (Test-Path (Join-Path $OutputDir $name))) {
        throw "Staged package is missing $name"
    }
}

$cabDir = Join-Path $OutputDir "cab"
New-Item -ItemType Directory -Path $cabDir | Out-Null
$ddf = Join-Path $cabDir "InvertMouse.ddf"
$cabName = "InvertMouseDriver_$Architecture.cab"

@(
    ".OPTION EXPLICIT",
    ".Set CabinetFileCountThreshold=0",
    ".Set FolderFileCountThreshold=0",
    ".Set FolderSizeThreshold=0",
    ".Set MaxCabinetSize=0",
    ".Set MaxDiskFileCount=0",
    ".Set MaxDiskSize=0",
    ".Set CompressionType=MSZIP",
    ".Set Cabinet=on",
    ".Set Compress=on",
    ".Set CabinetNameTemplate=$cabName",
    ".Set DiskDirectoryTemplate=.",
    ".Set DestinationDir=InvertMouse"
) | Set-Content -Path $ddf -Encoding ASCII

Get-ChildItem -Path $OutputDir -File | Where-Object { $_.Extension -in ".sys", ".inf", ".pdb" } | ForEach-Object {
    Add-Content -Path $ddf -Value ('"{0}"' -f $_.FullName) -Encoding ASCII
}

Push-Location $cabDir
try {
    & makecab.exe /f "InvertMouse.ddf"
    if ($LASTEXITCODE -ne 0) {
        throw "makecab failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$cab = Get-ChildItem -Path $cabDir -Filter *.cab | Select-Object -First 1
if (-not $cab) {
    throw "CAB was not created"
}

Copy-Item -Path $cab.FullName -Destination (Join-Path $OutputDir $cabName) -Force
Write-Host "Staged package: $OutputDir"
