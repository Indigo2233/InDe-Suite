[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$DllPath,

    [Parameter(Mandatory)]
    [string]$SignaturePath,

    [string]$BackendRoot,

    [string]$OnnxPythonPath,

    [string]$RepositoryOwner = 'Indigo2233',

    [string]$RepositoryName = 'InDe-Suite',

    [string]$ReleaseTag,

    [switch]$CpdSigned,

    [switch]$ModelDistributionAuthorized,

    [switch]$OverwriteSignedRepository
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($DllPath)) {
    $DllPath = Join-Path $moduleRoot 'build\bin\InDe-pxm.dll'
}
if ([string]::IsNullOrWhiteSpace($BackendRoot)) {
    $BackendRoot = Join-Path $moduleRoot 'backend'
}
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = "v$Version"
}

if (-not $CpdSigned) {
    throw 'Public PixInsight module releases require an explicit -CpdSigned confirmation.'
}
if (-not $ModelDistributionAuthorized) {
    throw 'Packaging model files requires an explicit -ModelDistributionAuthorized confirmation.'
}

foreach ($path in @($DllPath, $SignaturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file was not found: $path"
    }
}

if ([IO.Path]::GetExtension($SignaturePath) -ne '.xsgn') {
    throw 'SignaturePath must identify an .xsgn file.'
}

$dllInfo = Get-Item -LiteralPath $DllPath
$signatureInfo = Get-Item -LiteralPath $SignaturePath
if ($dllInfo.LastWriteTimeUtc -gt $signatureInfo.LastWriteTimeUtc) {
    throw 'The module DLL is newer than its signature. Sign the current DLL before packaging.'
}

$signatureText = Get-Content -LiteralPath $SignaturePath -Raw
$signatureMatch = [regex]::Match($signatureText, '<Signature\s+version="[^"]+"\s+developerId="([^"]+)">')
if (-not $signatureMatch.Success) {
    throw 'The supplied file does not contain a recognizable PixInsight code signature.'
}
$developerId = $signatureMatch.Groups[1].Value
$certifiedDevelopersPath = Join-Path $env:ProgramFiles 'PixInsight\etc\security\certified-developers.xcdev'
if (-not (Test-Path -LiteralPath $certifiedDevelopersPath -PathType Leaf)) {
    throw "PixInsight certified developer database was not found: $certifiedDevelopersPath"
}
$certifiedDevelopers = Get-Content -LiteralPath $certifiedDevelopersPath -Raw
$certifiedIds = @([regex]::Matches($certifiedDevelopers, '<Developer\b[^>]*\bid="([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
if ($certifiedIds -cnotcontains $developerId) {
    throw "The signature developerId '$developerId' is not present in PixInsight's certified developer database. A Local Signing Identity cannot be used for a public module release."
}

$requiredBackendFiles = @(
    'catalog.json',
    'engine\models\InDeConv.onnx',
    'engine\models\InDeNoise.onnx',
    'engine\models\InDeStars.onnx',
    'tools\inde_worker.py',
    'runtime\python.exe',
    'runtime\python313.dll',
    'runtime\python313._pth'
)
foreach ($relativePath in $requiredBackendFiles) {
    $source = Join-Path $BackendRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required backend file was not found: $source"
    }
}

$releaseRoot = Join-Path $moduleRoot 'release'
$packageBaseName = "InDe-$Version-windows-x64"
$stage = Join-Path $releaseRoot $packageBaseName
$archive = Join-Path $releaseRoot ($packageBaseName + '.zip')
$checksums = Join-Path $releaseRoot 'SHA256SUMS.txt'
$repositoryFile = Join-Path $moduleRoot 'updates.xri'

$releaseRootFull = [IO.Path]::GetFullPath($releaseRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$stageFull = [IO.Path]::GetFullPath($stage)
if (-not $stageFull.StartsWith($releaseRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The release staging directory resolved outside the repository release directory.'
}

if (Test-Path -LiteralPath $repositoryFile -PathType Leaf) {
    $existingRepository = Get-Content -LiteralPath $repositoryFile -Raw
    if ($existingRepository -match '<Signature\b' -and -not $OverwriteSignedRepository) {
        throw 'updates.xri is signed. Use -OverwriteSignedRepository to replace it with a newly generated unsigned document.'
    }
}

if (Test-Path -LiteralPath $stageFull) {
    Remove-Item -LiteralPath $stageFull -Recurse -Force
}
New-Item -ItemType Directory -Path $stageFull -Force | Out-Null

$binDirectory = Join-Path $stageFull 'bin'
$backendDirectory = Join-Path $binDirectory 'InDeBackend'
$engineDirectory = Join-Path $backendDirectory 'engine'
$modelsDirectory = Join-Path $engineDirectory 'models'
$toolsDirectory = Join-Path $backendDirectory 'tools'
$runtimeDirectory = Join-Path $backendDirectory 'runtime'
$sitePackagesDirectory = Join-Path $runtimeDirectory 'Lib\site-packages'
$modelSanitizer = Join-Path $moduleRoot 'tools\sanitize-release-model.py'
$sourceModelsDirectory = Join-Path $BackendRoot 'engine\models'
$documentationDirectory = Join-Path $stageFull 'doc\docs\InDe'

foreach ($directory in @(
    $binDirectory,
    $modelsDirectory,
    $toolsDirectory,
    $sitePackagesDirectory,
    $documentationDirectory
)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

Copy-Item -LiteralPath $DllPath -Destination (Join-Path $binDirectory 'InDe-pxm.dll') -Force
Copy-Item -LiteralPath $SignaturePath -Destination (Join-Path $binDirectory 'InDe-pxm.xsgn') -Force
Copy-Item -LiteralPath (Join-Path $BackendRoot 'catalog.json') -Destination $backendDirectory -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'backend\engine\run_models.py') -Destination $engineDirectory -Force
Copy-Item -Path (Join-Path $moduleRoot 'backend\tools\*.py') -Destination $toolsDirectory -Force
if (-not (Test-Path -LiteralPath $modelSanitizer -PathType Leaf)) {
    throw "Release model sanitizer was not found: $modelSanitizer"
}
if ([string]::IsNullOrWhiteSpace($OnnxPythonPath)) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $pythonCommand) {
        throw 'Python with the onnx package is required to prepare sanitized release models.'
    }
    $OnnxPythonPath = $pythonCommand.Source
}
foreach ($modelName in @('InDeConv.onnx', 'InDeNoise.onnx', 'InDeStars.onnx')) {
    $sourceModel = Join-Path $sourceModelsDirectory $modelName
    $destinationModel = Join-Path $modelsDirectory $modelName
    & $OnnxPythonPath -B -X utf8 $modelSanitizer --source $sourceModel --destination $destinationModel
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to sanitize release model: $modelName"
    }
}

$runtimeSource = Join-Path $BackendRoot 'runtime'
Get-ChildItem -LiteralPath $runtimeSource -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $runtimeDirectory -Force
}

$sitePackagesSource = Join-Path $runtimeSource 'Lib\site-packages'
$sitePackageNames = @(
    'numpy',
    'numpy.libs',
    'onnxruntime',
    'coloredlogs',
    'humanfriendly',
    'flatbuffers',
    'packaging',
    'google',
    'sympy',
    'mpmath',
    'cv2',
    'coloredlogs.pth'
)
$sitePackagePatterns = @(
    'numpy-*.dist-info',
    'onnxruntime_directml-*.dist-info',
    'coloredlogs-*.dist-info',
    'humanfriendly-*.dist-info',
    'flatbuffers-*.dist-info',
    'packaging-*.dist-info',
    'protobuf-*.dist-info',
    'sympy-*.dist-info',
    'mpmath-*.dist-info',
    'opencv_python_headless-*.dist-info'
)

foreach ($name in $sitePackageNames) {
    $source = Join-Path $sitePackagesSource $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required Python runtime component was not found: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $sitePackagesDirectory $name) -Recurse -Force
}
foreach ($pattern in $sitePackagePatterns) {
    $matches = @(Get-ChildItem -LiteralPath $sitePackagesSource -Filter $pattern)
    if ($matches.Count -eq 0) {
        throw "Required Python runtime component did not match: $pattern"
    }
    foreach ($match in $matches) {
        Copy-Item -LiteralPath $match.FullName -Destination (Join-Path $sitePackagesDirectory $match.Name) -Recurse -Force
    }
}

Copy-Item -LiteralPath (Join-Path $moduleRoot 'docs\INSTALL.zh-CN.md') -Destination $documentationDirectory -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'NOTICE.md') -Destination $documentationDirectory -Force
foreach ($relativePath in @('LICENSES.md', 'runtime-requirements.txt')) {
    $source = Join-Path $BackendRoot $relativePath
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination $documentationDirectory -Force
    }
}

$stagePython = Join-Path $runtimeDirectory 'python.exe'
$probe = @'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "engine"))
import run_models

result = {}
for product, file_name in run_models.FILES.items():
    session = run_models.make_session(root / "engine" / "models" / file_name, "cpu")
    result[product] = {
        "file": file_name,
        "providers": session.get_providers(),
        "inputs": [item.name for item in session.get_inputs()],
        "outputs": [item.name for item in session.get_outputs()],
    }
print(json.dumps(result, ensure_ascii=False))
'@
& $stagePython -I -B -X utf8 -c $probe $backendDirectory
if ($LASTEXITCODE -ne 0) {
    throw 'The staged InDe backend failed its ONNX session validation.'
}

Get-ChildItem -LiteralPath $stageFull -Directory -Filter '__pycache__' -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $stageFull -File -Filter '*.pyc' -Recurse -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force

if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
Compress-Archive -Path (Join-Path $stageFull '*') -DestinationPath $archive -CompressionLevel Optimal

$sha1 = (Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash.ToLowerInvariant()
$sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksums -Encoding ASCII -Value ("{0}  {1}" -f $sha256, (Split-Path -Leaf $archive))

$releaseDate = [DateTime]::UtcNow.ToString('yyyyMMdd')
$serverUrl = "https://github.com/$RepositoryOwner/$RepositoryName/releases/download/$ReleaseTag/"
$archiveName = Split-Path -Leaf $archive
$metadataId = "$releaseDate-inde-$Version"
$xri = @"
<?xml version="1.0" encoding="UTF-8"?>
<xri version="1.0">
   <description>
      <p>InDe-Suite native PixInsight processes with a self-contained Windows inference backend.</p>
   </description>
   <metadata id="$metadataId" releaseDate="$releaseDate">
      <title>InDe-Suite $Version for Windows x64</title>
      <description>
         <p>Installs InDeConv, InDeStars and InDeNoise with Real-Time Preview support and the complete local ONNX backend.</p>
      </description>
   </metadata>
   <platform os="windows" arch="x64" version="1.9.0:1.9.99">
      <package fileName="$archiveName" sha1="$sha1" type="module" metadata="$metadataId" serverURL="$serverUrl"/>
   </platform>
</xri>
"@
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($repositoryFile, $xri, $utf8WithoutBom)

$archiveInfo = Get-Item -LiteralPath $archive
Write-Host "Release archive: $archive"
Write-Host ("Archive size: {0:N2} MiB" -f ($archiveInfo.Length / 1MB))
Write-Host "SHA-1: $sha1"
Write-Host "SHA-256: $sha256"
Write-Host "Unsigned repository document: $repositoryFile"
Write-Host 'Sign updates.xri after the package and release URL are final.'
