[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$DllPath,

    [string]$BackendRoot,

    [string]$OnnxPythonPath,

    [switch]$ModelDistributionAuthorized
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($DllPath)) {
    $DllPath = Join-Path $moduleRoot 'build\bin\InDe-pxm.dll'
}
if ([string]::IsNullOrWhiteSpace($BackendRoot)) {
    $BackendRoot = Join-Path $moduleRoot 'backend'
}
if (-not $ModelDistributionAuthorized) {
    throw 'Packaging model files requires an explicit -ModelDistributionAuthorized confirmation.'
}
if (-not (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
    throw "Required module was not found: $DllPath"
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
$packageBaseName = "InDe-$Version-local-windows-x64"
$stage = Join-Path $releaseRoot $packageBaseName
$archive = Join-Path $releaseRoot ($packageBaseName + '.zip')
$checksums = Join-Path $releaseRoot 'SHA256SUMS-local.txt'
$setupBaseName = "InDe-$Version-setup-windows"
$setupStage = Join-Path $releaseRoot $setupBaseName
$setupArchive = Join-Path $releaseRoot ($setupBaseName + '.zip')
$releaseRootFull = [IO.Path]::GetFullPath($releaseRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$stageFull = [IO.Path]::GetFullPath($stage)
if (-not $stageFull.StartsWith($releaseRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The release staging directory resolved outside the repository release directory.'
}
if (Test-Path -LiteralPath $stageFull) {
    Remove-Item -LiteralPath $stageFull -Recurse -Force
}
New-Item -ItemType Directory -Path $stageFull -Force | Out-Null

$backendDirectory = Join-Path $stageFull 'InDeBackend'
$engineDirectory = Join-Path $backendDirectory 'engine'
$modelsDirectory = Join-Path $engineDirectory 'models'
$toolsDirectory = Join-Path $backendDirectory 'tools'
$runtimeDirectory = Join-Path $backendDirectory 'runtime'
$sitePackagesDirectory = Join-Path $runtimeDirectory 'Lib\site-packages'
$modelSanitizer = Join-Path $moduleRoot 'tools\sanitize-release-model.py'
$sourceModelsDirectory = Join-Path $BackendRoot 'engine\models'
$docsDirectory = Join-Path $stageFull 'docs'
$testDirectory = Join-Path $stageFull 'test'
foreach ($directory in @($modelsDirectory, $toolsDirectory, $sitePackagesDirectory, $docsDirectory, $testDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

Copy-Item -LiteralPath $DllPath -Destination (Join-Path $stageFull 'InDe-pxm.dll') -Force
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
    'numpy', 'numpy.libs', 'onnxruntime', 'coloredlogs', 'humanfriendly',
    'flatbuffers', 'packaging', 'google', 'sympy', 'mpmath', 'cv2', 'coloredlogs.pth'
)
$sitePackagePatterns = @(
    'numpy-*.dist-info', 'onnxruntime_directml-*.dist-info', 'coloredlogs-*.dist-info',
    'humanfriendly-*.dist-info', 'flatbuffers-*.dist-info', 'packaging-*.dist-info',
    'protobuf-*.dist-info', 'sympy-*.dist-info', 'mpmath-*.dist-info',
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

Copy-Item -LiteralPath (Join-Path $moduleRoot 'install-local.ps1') -Destination $stageFull -Force
foreach ($installerFile in @('Install-Windows.cmd', 'setup-windows.ps1', 'installer-common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $moduleRoot $installerFile) -Destination $stageFull -Force
}
Copy-Item -LiteralPath (Join-Path $moduleRoot 'AGENTS.md') -Destination $stageFull -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'README.md') -Destination $stageFull -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'NOTICE.md') -Destination $stageFull -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'docs\INSTALL.zh-CN.md') -Destination $docsDirectory -Force
Copy-Item -LiteralPath (Join-Path $moduleRoot 'test\native-selftest.js') -Destination $testDirectory -Force
foreach ($relativePath in @('LICENSES.md', 'runtime-requirements.txt')) {
    $source = Join-Path $BackendRoot $relativePath
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination $docsDirectory -Force
    }
}

$stagePython = Join-Path $runtimeDirectory 'python.exe'
$probe = @'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'engine'))
import run_models

result = {}
for product, file_name in run_models.FILES.items():
    session = run_models.make_session(root / 'engine' / 'models' / file_name, 'cpu')
    result[product] = {
        'file': file_name,
        'providers': session.get_providers(),
        'inputs': [item.name for item in session.get_inputs()],
        'outputs': [item.name for item in session.get_outputs()],
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

if (Get-ChildItem -LiteralPath $stageFull -Filter '*.xsgn' -File -Recurse) {
    throw 'Local signature files must not be included in a public release.'
}
if (Get-ChildItem -LiteralPath $stageFull -Filter '*.xssk' -File -Recurse) {
    throw 'Private keys must not be included in a public release.'
}

# Hash each extracted file so the offline installer can also check integrity.
$manifestFiles = @(Get-ChildItem -LiteralPath $stageFull -File -Recurse | Sort-Object FullName | ForEach-Object {
    @{
        path = $_.FullName.Substring($stageFull.Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
@{ schema = 1; platform = 'windows-x64'; version = $Version; files = $manifestFiles } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stageFull 'package-manifest.json') -Encoding UTF8
if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
Compress-Archive -Path (Join-Path $stageFull '*') -DestinationPath $archive -CompressionLevel Optimal
$sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()

# Small bootstrap download: no model/runtime files, uses the same setup UI.
$setupStageFull = [IO.Path]::GetFullPath($setupStage)
if (-not $setupStageFull.StartsWith($releaseRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The setup staging directory resolved outside release.'
}
if (Test-Path -LiteralPath $setupStageFull) { Remove-Item -LiteralPath $setupStageFull -Recurse -Force }
New-Item -ItemType Directory -Path $setupStageFull -Force | Out-Null
foreach ($installerFile in @('Install-Windows.cmd', 'setup-windows.ps1', 'installer-common.ps1')) {
    Copy-Item -LiteralPath (Join-Path $moduleRoot $installerFile) -Destination $setupStageFull -Force
}
# Remember the packaged version even if the source default changes later.
$setupScriptPath = Join-Path $setupStageFull 'setup-windows.ps1'
$setupScript = Get-Content -LiteralPath $setupScriptPath -Raw
$setupScript.Replace("[string]`$ReleaseTag = 'v1.0.2-local'", "[string]`$ReleaseTag = 'v$Version-local'") |
    Set-Content -LiteralPath $setupScriptPath -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $moduleRoot 'docs\INSTALL.zh-CN.md') -Destination $setupStageFull -Force
if (Test-Path -LiteralPath $setupArchive) { Remove-Item -LiteralPath $setupArchive -Force }
Compress-Archive -Path (Join-Path $setupStageFull '*') -DestinationPath $setupArchive -CompressionLevel Optimal
$setupSha = (Get-FileHash -LiteralPath $setupArchive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksums -Encoding ASCII -Value @(
    ("{0}  {1}" -f $sha256, (Split-Path -Leaf $archive)),
    ("{0}  {1}" -f $setupSha, (Split-Path -Leaf $setupArchive))
)

$archiveInfo = Get-Item -LiteralPath $archive
Write-Host "Local signing release archive: $archive"
Write-Host ("Archive size: {0:N2} MiB" -f ($archiveInfo.Length / 1MB))
Write-Host "SHA-256: $sha256"
Write-Host "Checksums: $checksums"
Write-Host "Double-click setup archive: $setupArchive"
