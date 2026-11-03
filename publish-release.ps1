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
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = "v$Version"
}
if (-not $ConfirmPublicRelease) {
    throw 'Publishing requires an explicit -ConfirmPublicRelease confirmation.'
}

$archiveName = "InDe-$Version-windows-x64.zip"
$archive = Join-Path $moduleRoot "release\$archiveName"
$checksums = Join-Path $moduleRoot 'release\SHA256SUMS.txt'
$repositoryFile = Join-Path $moduleRoot 'updates.xri'
foreach ($path in @($archive, $checksums, $repositoryFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release artifact was not found: $path"
    }
}

$xri = Get-Content -LiteralPath $repositoryFile -Raw
$repositorySignature = [regex]::Match($xri, '<Signature\b[^>]*developerId="([^"]+)"')
if (-not $repositorySignature.Success) {
    throw 'updates.xri must carry a PixInsight repository signature before publication.'
}
$developerId = $repositorySignature.Groups[1].Value
$certifiedDevelopersPath = Join-Path $env:ProgramFiles 'PixInsight\etc\security\certified-developers.xcdev'
if (-not (Test-Path -LiteralPath $certifiedDevelopersPath -PathType Leaf)) {
    throw "PixInsight certified developer database was not found: $certifiedDevelopersPath"
}
$certifiedDevelopers = Get-Content -LiteralPath $certifiedDevelopersPath -Raw
$certifiedIds = @([regex]::Matches($certifiedDevelopers, '<Developer\b[^>]*\bid="([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
if ($certifiedIds -cnotcontains $developerId) {
    throw "The repository signature developerId '$developerId' is not a Certified PixInsight Developer identity."
}
if ($xri -notmatch ('fileName="' + [regex]::Escape($archiveName) + '"')) {
    throw 'updates.xri does not reference the expected release archive.'
}

$sha1 = (Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash.ToLowerInvariant()
if ($xri -notmatch ('sha1="' + $sha1 + '"')) {
    throw 'The release archive SHA-1 does not match updates.xri.'
}

& gh auth status | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

& gh release view $ReleaseTag --repo $Repository *> $null
if ($LASTEXITCODE -eq 0) {
    & gh release upload $ReleaseTag $archive $checksums --repo $Repository --clobber
}
else {
    $notes = @"
InDe-Suite $Version for PixInsight on Windows x64.

Install through PixInsight Resources > Updates > Manage Repositories using:
https://raw.githubusercontent.com/$Repository/main/
"@
    & gh release create $ReleaseTag $archive $checksums --repo $Repository --title "InDe-Suite $Version" --notes $notes
}
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub Release publication failed.'
}

Write-Host "Published GitHub Release: https://github.com/$Repository/releases/tag/$ReleaseTag"
