function Get-KitTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Tools",
        "${env:ProgramFiles}\Windows Kits\10\bin",
        "${env:ProgramFiles}\Windows Kits\10\Tools"
    )

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) {
            continue
        }

        $match = Get-ChildItem -Path $root -Filter $Name -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1

        if ($match) {
            return $match.FullName
        }
    }

    return $null
}
