[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KeysFile,

    [string]$PixInsightRoot = (Join-Path $env:ProgramFiles 'PixInsight'),

    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\InDe')
)

$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $packageRoot 'installer-common.ps1')
$sourceDll = Join-Path $packageRoot 'InDe-pxm.dll'
$sourceBackend = Join-Path $packageRoot 'InDeBackend'
$sourceTest = Join-Path $packageRoot 'test\native-selftest.js'
$pixInsightExe = Join-Path $PixInsightRoot 'bin\PixInsight.exe'

Assert-InDeDestination $Destination $packageRoot $PixInsightRoot
Test-InDePackage $packageRoot
if ((Get-InDePEMachine $pixInsightExe) -ne 0x8664) {
    throw 'This package requires x64 PixInsight.'
}

foreach ($path in @($sourceDll, $sourceTest, $pixInsightExe, $KeysFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file was not found: $path"
    }
}
if (-not (Test-Path -LiteralPath $sourceBackend -PathType Container)) {
    throw "Required backend directory was not found: $sourceBackend"
}

$requiredBackendFiles = @(
    'runtime\python.exe',
    'engine\run_models.py',
    'engine\models\InDeConv.onnx',
    'engine\models\InDeNoise.onnx',
    'engine\models\InDeStars.onnx',
    'tools\inde_worker.py'
)
foreach ($relativePath in $requiredBackendFiles) {
    $path = Join-Path $sourceBackend $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required backend file was not found: $path"
    }
}

$keysFullPath = (Resolve-Path -LiteralPath $KeysFile).Path
if ([IO.Path]::GetExtension($keysFullPath) -ine '.xssk') {
    throw 'KeysFile must be a PixInsight .xssk file.'
}
if ($keysFullPath -match '[^\x00-\x7F]') {
    throw 'The .xssk path must contain ASCII characters only because the PixInsight Windows signing command cannot decode this path safely.'
}
if (Get-Process PixInsight -ErrorAction SilentlyContinue) {
    throw 'PixInsight is running. Close every PixInsight window before local signing.'
}

$publicRoot = [Environment]::GetFolderPath('CommonDocuments')
if ([string]::IsNullOrWhiteSpace($publicRoot) -or $publicRoot -match '[^\x00-\x7F]') {
    throw 'An ASCII-only public documents directory is required for temporary module signing.'
}
$signingParent = Join-Path $publicRoot 'InDeSigning'
$signingDirectory = Join-Path $signingParent ([guid]::NewGuid().ToString('N'))
$stageDll = Join-Path $signingDirectory 'InDe-pxm.dll'
$stageSignature = Join-Path $signingDirectory 'InDe-pxm.xsgn'

try {
    New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourceDll -Destination $stageDll -Force

    Write-Host 'PixInsight will request the Local Signing Identity password.'
    Write-Host 'Enter the password in the PixInsight dialog. The installer does not read or store it.'

    $arguments = @(
        "--sign-module-file=`"$stageDll`"",
        "--xssk-file=`"$keysFullPath`""
    )
    $signingProcess = Start-Process -FilePath $pixInsightExe -ArgumentList $arguments -PassThru -Wait
    if ($signingProcess.ExitCode -ne 0) {
        throw "PixInsight signing failed with exit code $($signingProcess.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $stageSignature -PathType Leaf)) {
        throw 'PixInsight did not generate InDe-pxm.xsgn.'
    }

    $sourceHash = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash
    $stageHash = (Get-FileHash -LiteralPath $stageDll -Algorithm SHA256).Hash
    if ($sourceHash -ne $stageHash) {
        throw 'The staged module differs from the release module.'
    }

    $signatureText = Get-Content -LiteralPath $stageSignature -Raw
    $signatureMatch = [regex]::Match($signatureText, '<Signature\s+version="[^"]+"\s+developerId="([^"]+)">')
    if (-not $signatureMatch.Success) {
        throw 'The generated PixInsight signature has an unrecognized format.'
    }

    # A user may have started PixInsight while the signing dialog was open.
    if (Get-Process PixInsight -ErrorAction SilentlyContinue) {
        throw 'Close all PixInsight windows and run setup again before replacing installed files.'
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath $stageDll -Destination (Join-Path $Destination 'InDe-pxm.dll') -Force
    Copy-Item -LiteralPath $stageSignature -Destination (Join-Path $Destination 'InDe-pxm.xsgn') -Force

    $backendDestination = Join-Path $Destination 'InDeBackend'
    New-Item -ItemType Directory -Path $backendDestination -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceBackend | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $backendDestination $_.Name) -Recurse -Force
    }

    $testDestination = Join-Path $Destination 'test'
    New-Item -ItemType Directory -Path $testDestination -Force | Out-Null
    Copy-Item -LiteralPath $sourceTest -Destination $testDestination -Force

    $docsDestination = Join-Path $Destination 'docs'
    New-Item -ItemType Directory -Path $docsDestination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packageRoot 'docs\INSTALL.zh-CN.md') -Destination $docsDestination -Force

    Write-Host "Installed module: $(Join-Path $Destination 'InDe-pxm.dll')"
    Write-Host "Installed signature: $(Join-Path $Destination 'InDe-pxm.xsgn')"
    Write-Host "Local developer ID: $($signatureMatch.Groups[1].Value)"
    Write-Host "SHA-256: $sourceHash"
    Write-Host ''
    Write-Host 'Next step:'
    Write-Host '1. Start PixInsight.'
    Write-Host '2. Open Process > Modules > Install Modules.'
    Write-Host "3. Select this directory: $Destination"
    Write-Host '4. Restart PixInsight and run test\native-selftest.js.'
}
finally {
    $signingParentFull = [IO.Path]::GetFullPath($signingParent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $signingDirectoryFull = [IO.Path]::GetFullPath($signingDirectory)
    if ($signingDirectoryFull.StartsWith($signingParentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $signingDirectoryFull)) {
        Remove-Item -LiteralPath $signingDirectoryFull -Recurse -Force
    }
}
