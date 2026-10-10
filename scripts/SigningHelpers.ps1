#Requires -Version 5.1
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host ("==> {0}" -f $Message)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgumentList
    )

    Write-Verbose ("{0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    & $FilePath @ArgumentList
    if ($LASTEXITCODE) {
        throw ("{0} exited with code {1}" -f $FilePath, $LASTEXITCODE)
    }
}

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    return (Get-Location).Path
}

function Get-MsBuildPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found at $vswhere"
    }

    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
        Select-Object -First 1
    if (-not $msbuild -or -not (Test-Path -LiteralPath $msbuild)) {
        throw 'MSBuild.exe not found via vswhere'
    }

    return $msbuild
}

function Assert-WdkWhereInstalled {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Push-Location $RepoRoot
    try {
        $listed = & dotnet tool list --local
        if ($LASTEXITCODE) {
            throw ("dotnet tool list --local exited with code {0}" -f $LASTEXITCODE)
        }
    }
    finally {
        Pop-Location
    }

    if (-not ($listed | Where-Object { $_ -match 'nefarius\.tools\.wdkwhere' })) {
        throw 'wdkwhere is not installed. Run "dotnet tool restore" from the repository root.'
    }
}

function Initialize-WdkPath {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Push-Location $RepoRoot
    try {
        Assert-WdkWhereInstalled -RepoRoot $RepoRoot
        $kitQuery = & dotnet wdkwhere 2>&1
        if ($LASTEXITCODE) {
            throw ("wdkwhere failed (exit {0}): {1}" -f $LASTEXITCODE, ($kitQuery | Out-String).Trim())
        }

        $kitBin = ($kitQuery | Out-String).Trim()
        if (-not $kitBin -or -not (Test-Path -LiteralPath $kitBin)) {
            throw ("dotnet wdkwhere did not return a usable Windows kit bin directory: {0}" -f $kitBin)
        }

        $env:PATH = "$kitBin;$env:PATH"
        $sdkRoot = (Resolve-Path -LiteralPath (Join-Path $kitBin '..\..\..')).Path
        if (-not $sdkRoot.EndsWith('\')) {
            $sdkRoot += '\'
        }
        $env:WindowsSdkDir = $sdkRoot
        Write-Host ("    Kit bin: {0}" -f $kitBin)
        Write-Host ("    WindowsSdkDir: {0}" -f $env:WindowsSdkDir)
    }
    finally {
        Pop-Location
    }
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$SignToolPath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    if ($SignToolPath) {
        if (-not (Test-Path -LiteralPath $SignToolPath)) {
            throw "SignToolPath not found: $SignToolPath"
        }
        Invoke-Native -FilePath $SignToolPath @ArgumentList
        return
    }

    Push-Location $RepoRoot
    try {
        Assert-WdkWhereInstalled -RepoRoot $RepoRoot
        Invoke-Native -FilePath 'dotnet' -ArgumentList (@('wdkwhere', 'run', 'signtool') + $ArgumentList)
    }
    finally {
        Pop-Location
    }
}

function Test-IsSigned {
    param([Parameter(Mandatory)][string]$Path)

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    return ($null -ne $sig.SignerCertificate -and $sig.Status -ne 'NotSigned')
}

function Remove-EmbeddedSignature {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [string]$SignToolPath
    )

    if (-not (Test-IsSigned -Path $Path)) {
        Write-Host ("    unsigned: {0}" -f $Path)
    }
    else {
        Write-Host ("    strip:    {0}" -f $Path)
        Invoke-SignTool -RepoRoot $RepoRoot -SignToolPath $SignToolPath -ArgumentList @('remove', '/s', $Path)
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'NotSigned') {
        throw ("Failed to strip signature from {0} (Status={1})" -f $Path, $sig.Status)
    }
}

function Add-EmbeddedSignature {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [string]$SignToolPath,
        [string]$CertificateSubject,
        [string]$CertificateThumbprint,
        [Parameter(Mandatory)][string]$TimestampUrl
    )

    $args = @(
        'sign',
        '/tr', $TimestampUrl,
        '/td', 'sha256',
        '/fd', 'sha256'
    )

    if ($CertificateThumbprint) {
        $args += @('/sha1', $CertificateThumbprint)
    }
    else {
        $args += @('/n', $CertificateSubject)
    }

    $args += $Path
    Write-Host ("    sign:     {0}" -f $Path)
    Invoke-SignTool -RepoRoot $RepoRoot -SignToolPath $SignToolPath -ArgumentList $args
}

function Confirm-EmbeddedSignature {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [string]$SignToolPath
    )

    # /pa is Authenticode (the EV publisher signature). /kp is kernel
    # policy and only succeeds after Microsoft attestation.
    Invoke-SignTool -RepoRoot $RepoRoot -SignToolPath $SignToolPath -ArgumentList @('verify', '/pa', '/v', $Path)

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -eq 'NotSigned' -or -not $sig.SignerCertificate) {
        throw "File is not signed: $Path (Status=$($sig.Status))"
    }
    if ($sig.Status -eq 'HashMismatch') {
        throw "File signature is invalid: $Path (Status=$($sig.Status))"
    }
    if ($sig.Status -ne 'Valid') {
        throw "File signature is not Valid: $Path (Status=$($sig.Status))"
    }

    Write-Host ("    verified: {0} ({1})" -f $Path, $sig.SignerCertificate.Subject)
}

function Assert-SigningIdentity {
    param(
        [string]$CertificateSubject,
        [string]$CertificateThumbprint
    )

    if (-not $CertificateThumbprint -and -not $CertificateSubject) {
        throw 'Specify -CertificateSubject or -CertificateThumbprint, or pass -SkipSigning.'
    }
}
