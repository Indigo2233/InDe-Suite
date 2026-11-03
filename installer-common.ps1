# Shared, non-interactive validation. Compatible with Windows PowerShell 5.1.
Set-StrictMode -Version 2.0

function Get-InDeFullPath {
    param([string]$Path)
    # Resolve relative arguments against PowerShell's location, which can differ
    # from the process working directory after Set-Location.
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Get-InDeExpectedHash {
    param([string]$Checksums, [string]$FileName)
    $found = @()
    foreach ($line in ($Checksums -split '\r?\n')) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -ceq $FileName) {
            $found += $Matches[1].ToLowerInvariant()
        }
    }
    if ($found.Count -ne 1) { throw "Expected exactly one checksum for $FileName." }
    return $found[0]
}

function Get-InDeChildPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':') -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Invalid package path: $RelativePath"
    }
    $rootFull = (Get-InDeFullPath $Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package path leaves its root: $RelativePath"
    }
    return $full
}

function Test-InDePackage {
    param([string]$PackageRoot)
    $manifestPath = Join-Path $PackageRoot 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.platform -ne 'windows-x64' -or @($manifest.files).Count -eq 0) {
        throw 'Unsupported or empty package manifest.'
    }
    $seen = @{}
    foreach ($entry in $manifest.files) {
        $path = Get-InDeChildPath $PackageRoot $entry.path
        if ($seen.ContainsKey($path)) { throw "Duplicate package path: $($entry.path)" }
        $seen[$path] = $true
        if ($entry.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Invalid or missing package file: $($entry.path)"
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) {
            throw "Package file checksum mismatch: $($entry.path). Download and extract the package again."
        }
    }
    foreach ($required in @('InDe-pxm.dll', 'install-local.ps1', 'installer-common.ps1',
        'InDeBackend/runtime/python.exe', 'InDeBackend/engine/run_models.py',
        'InDeBackend/tools/inde_worker.py', 'InDeBackend/engine/models/InDeConv.onnx',
        'InDeBackend/engine/models/InDeNoise.onnx', 'InDeBackend/engine/models/InDeStars.onnx',
        'test/native-selftest.js')) {
        if (-not $seen.ContainsKey((Get-InDeChildPath $PackageRoot $required))) {
            throw "Package manifest omits a required file: $required"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force) {
        if ($file.FullName -ine (Get-InDeFullPath $manifestPath) -and -not $seen.ContainsKey($file.FullName)) {
            throw "Unlisted package file: $($file.FullName). Extract a fresh package."
        }
    }
}

function Assert-InDeDestination {
    param([string]$Destination, [string]$PackageRoot, [string]$PixInsightRoot)
    $target = (Get-InDeFullPath $Destination).TrimEnd('\', '/')
    $drive = [IO.Path]::GetPathRoot($target).TrimEnd('\', '/')
    if ($target -eq $drive) { throw 'Choose a dedicated InDe installation directory.' }
    foreach ($protected in @($PackageRoot, $PixInsightRoot, $env:USERPROFILE, $env:LOCALAPPDATA, $env:ProgramFiles)) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        $protectedFull = (Get-InDeFullPath $protected).TrimEnd('\', '/')
        if ($target -ieq $protectedFull -or
            $protectedFull.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installation destination overlaps a protected directory: $target"
        }
    }
    $packageFull = (Get-InDeFullPath $PackageRoot).TrimEnd('\', '/')
    if ($target.StartsWith($packageFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation destination must be outside the downloaded package.'
    }
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Container)) {
        throw 'The installation destination must be a directory.'
    }
    if ((Test-Path -LiteralPath $target -PathType Container) -and
        @(Get-ChildItem -LiteralPath $target -Force).Count -gt 0 -and
        -not (Test-Path -LiteralPath (Join-Path $target 'InDe-pxm.dll') -PathType Leaf)) {
        throw 'This nonempty directory is not an existing InDe installation. Choose a dedicated directory.'
    }
}

function Get-InDePEMachine {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid Windows executable: $Path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt $stream.Length - 6) { throw 'Invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE signature.' }
        return $reader.ReadUInt16()
    }
    finally { $reader.Dispose() }
}
