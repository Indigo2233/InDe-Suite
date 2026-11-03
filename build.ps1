[CmdletBinding()]
param(
    [switch]$RebuildPcl,
    [string]$PixInsightRoot = $env:PIXINSIGHT_ROOT,
    [string]$MSBuildPath = $env:MSBUILD_EXE
)

$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pixInsightCandidates = @(
    $PixInsightRoot,
    (Join-Path $env:ProgramFiles 'PixInsight')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$pixInsightRoot = $pixInsightCandidates |
    Where-Object {
        (Test-Path -LiteralPath (Join-Path $_ 'include') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $_ 'src') -PathType Container)
    } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($pixInsightRoot)) {
    throw 'PixInsight development files were not found. Pass -PixInsightRoot or set PIXINSIGHT_ROOT.'
}

$pixInsightRoot = (Resolve-Path -LiteralPath $pixInsightRoot).Path
$pclSourceRoot = Join-Path $pixInsightRoot 'src'
$pclInclude = Join-Path $pixInsightRoot 'include'
$buildRoot = Join-Path $moduleRoot 'build'
$libraryDirectory = Join-Path $buildRoot 'lib'
$binaryDirectory = Join-Path $buildRoot 'bin'
$objectDirectory = Join-Path $buildRoot 'obj'

$msbuildCandidates = @($MSBuildPath)
$msbuildCommand = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if ($null -ne $msbuildCommand) {
    $msbuildCandidates += $msbuildCommand.Source
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $detectedMSBuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' |
        Select-Object -First 1
    $msbuildCandidates += $detectedMSBuild
}

$msbuildCandidates += @(
    'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
)

$msbuild = $msbuildCandidates |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Leaf)
    } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($msbuild)) {
    throw 'MSBuild was not found. Pass -MSBuildPath or set MSBUILD_EXE.'
}

$msbuild = (Resolve-Path -LiteralPath $msbuild).Path

Write-Host "PixInsight: $pixInsightRoot"
Write-Host "MSBuild: $msbuild"

foreach ($directory in @($libraryDirectory, $binaryDirectory, $objectDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$commonProperties = @(
    '/m',
    '/nologo',
    '/verbosity:minimal',
    '/p:Configuration=Release',
    '/p:Platform=x64',
    "/p:PCLINCDIR=$pclInclude",
    "/p:PCLSRCDIR=$pclSourceRoot",
    "/p:PCLLIBDIR64=$libraryDirectory",
    "/p:PCLBINDIR64=$binaryDirectory"
)

$dependencies = @(
    @{ Name = 'lz4'; Project = Join-Path $pclSourceRoot '3rdparty\lz4\windows\vc17\lz4.vcxproj' },
    @{ Name = 'zstd'; Project = Join-Path $pclSourceRoot '3rdparty\zstd\windows\vc17\zstd.vcxproj' },
    @{ Name = 'zlib'; Project = Join-Path $pclSourceRoot '3rdparty\zlib\windows\vc17\zlib.vcxproj' },
    @{ Name = 'RFC6234'; Project = Join-Path $pclSourceRoot '3rdparty\RFC6234\windows\vc17\RFC6234.vcxproj' },
    @{ Name = 'lcms'; Project = Join-Path $pclSourceRoot '3rdparty\lcms\windows\vc17\lcms.vcxproj' },
    @{ Name = 'PCL'; Project = Join-Path $pclSourceRoot 'pcl\windows\vc17\PCL.vcxproj' }
)

foreach ($dependency in $dependencies) {
    $expectedLibrary = Join-Path $libraryDirectory ($dependency.Name + '-pxi.lib')
    if ($dependency.Name -eq 'PCL') {
        $expectedLibrary = Join-Path $libraryDirectory 'PCL-pxi.lib'
    }
    if ($RebuildPcl -or -not (Test-Path -LiteralPath $expectedLibrary -PathType Leaf)) {
        Write-Host "Building $($dependency.Name)..."
        $dependencyObjectDirectory = Join-Path $objectDirectory $dependency.Name
        New-Item -ItemType Directory -Path $dependencyObjectDirectory -Force | Out-Null
        & $msbuild $dependency.Project @commonProperties "/p:IntDir=$dependencyObjectDirectory\"
        if ($LASTEXITCODE -ne 0) {
            throw "$($dependency.Name) build failed with exit code $LASTEXITCODE"
        }
    }
}

$project = Join-Path $moduleRoot 'src\windows\vc17\InDe.vcxproj'
$moduleObjectDirectory = Join-Path $objectDirectory 'InDe'
New-Item -ItemType Directory -Path $moduleObjectDirectory -Force | Out-Null

$existingSignature = Join-Path $binaryDirectory 'InDe-pxm.xsgn'
if (Test-Path -LiteralPath $existingSignature -PathType Leaf) {
    $staleDirectory = Join-Path $buildRoot 'stale-signatures'
    New-Item -ItemType Directory -Path $staleDirectory -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $staleSignature = Join-Path $staleDirectory "InDe-pxm-$timestamp.xsgn"
    Move-Item -LiteralPath $existingSignature -Destination $staleSignature
    Write-Warning "Archived the previous signature because rebuilding changes the DLL: $staleSignature"
}

Write-Host 'Building InDe module...'
& $msbuild $project @commonProperties "/p:INDEOBJDIR=$moduleObjectDirectory"
if ($LASTEXITCODE -ne 0) {
    throw "InDe module build failed with exit code $LASTEXITCODE"
}

$output = Join-Path $binaryDirectory 'InDe-pxm.dll'
Write-Host "Built: $output"
