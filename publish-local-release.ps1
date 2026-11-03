[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$Repository = 'Indigo2233/InDe-Suite',

    [string]$ReleaseTag,

    [switch]$ConfirmPublicRelease
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $moduleRoot 'installer-common.ps1')
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = "v$Version-local"
}
if (-not $ConfirmPublicRelease) {
    throw 'Publishing requires an explicit -ConfirmPublicRelease confirmation.'
}

$archiveName = "InDe-$Version-local-windows-x64.zip"
$archive = Join-Path $moduleRoot "release\$archiveName"
$checksums = Join-Path $moduleRoot 'release\SHA256SUMS-local.txt'
$setupArchive = Join-Path $moduleRoot "release\InDe-$Version-setup-windows.zip"
foreach ($path in @($archive, $setupArchive, $checksums)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release artifact was not found: $path"
    }
}

$checksumLine = Get-Content -LiteralPath $checksums -Raw
foreach ($asset in @($archive, $setupArchive)) {
    $expected = Get-InDeExpectedHash $checksumLine (Split-Path -Leaf $asset)
    if ((Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash -ine $expected) {
        throw "Release asset checksum mismatch: $asset"
    }
}

& gh auth status | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

$notes = @"
InDe-Suite $Version Local Signing Edition for PixInsight 1.9.x on Windows x64.

This package contains InDeConv, InDeStars and InDeNoise, the self-contained inference runtime, and the project-owned InDeConv, InDeNoise and InDeStars models.

Recommended: download InDe-$Version-setup-windows.zip, extract it, and double-click Install-Windows.cmd. The wizard locates PixInsight, guides first-time local signing setup, downloads and verifies the complete package, and installs the module and backend. Select your .xssk file and enter the signing password only in PixInsight. Finish with Process > Modules > Install Modules and restart PixInsight.

For offline installation, download InDe-$Version-local-windows-x64.zip and SHA256SUMS-local.txt. Verify the ZIP checksum, extract it, and double-click Install-Windows.cmd. Both ZIP checksums are listed in SHA256SUMS-local.txt.

Detailed signing-key and installation instructions: https://github.com/$Repository/blob/main/docs/INSTALL.zh-CN.md

Windows x64 is currently supported. macOS Intel and Apple Silicon packages are not yet available. The three ONNX model files can be shared across platforms; macOS native modules and runtimes require separate builds and validation.

This release cannot be installed through Manage Repositories because the module does not carry a Certified PixInsight Developer signature.
"@

$notesFile = Join-Path ([IO.Path]::GetTempPath()) ('inde-release-notes-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))
    & gh release view $ReleaseTag --repo $Repository *> $null
    if ($LASTEXITCODE -eq 0) {
        & gh release upload $ReleaseTag $archive $setupArchive $checksums --repo $Repository --clobber
        if ($LASTEXITCODE -ne 0) { throw 'Release asset upload failed; release notes were not changed.' }
        & gh release edit $ReleaseTag --repo $Repository --title "InDe-Suite $Version Local Signing Edition" --notes-file $notesFile
    }
    else {
        & gh release create $ReleaseTag $archive $setupArchive $checksums --repo $Repository --title "InDe-Suite $Version Local Signing Edition" --notes-file $notesFile
    }
    if ($LASTEXITCODE -ne 0) { throw 'GitHub Release publication failed.' }
}
finally {
    if (Test-Path -LiteralPath $notesFile -PathType Leaf) { Remove-Item -LiteralPath $notesFile -Force }
}

Write-Host "Published GitHub Release: https://github.com/$Repository/releases/tag/$ReleaseTag"
