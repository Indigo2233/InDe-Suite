[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\InDe')
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $moduleRoot 'build\bin\InDe-pxm.dll'
$signature = Join-Path $moduleRoot 'build\bin\InDe-pxm.xsgn'

if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'InDe-pxm.dll has not been built. Run build.ps1 first.'
}

if (-not (Test-Path -LiteralPath $signature -PathType Leaf)) {
    throw 'InDe-pxm.xsgn is missing. Sign the current DLL before installation.'
}

$sourceInfo = Get-Item -LiteralPath $source
$signatureInfo = Get-Item -LiteralPath $signature
if ($sourceInfo.LastWriteTimeUtc -gt $signatureInfo.LastWriteTimeUtc) {
    throw 'InDe-pxm.dll is newer than InDe-pxm.xsgn. Sign the current DLL before installation.'
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$target = Join-Path $Destination 'InDe-pxm.dll'
$signatureTarget = Join-Path $Destination 'InDe-pxm.xsgn'

Copy-Item -LiteralPath $source -Destination $target -Force
Copy-Item -LiteralPath $signature -Destination $signatureTarget -Force

Write-Host "Installed module file: $target"
Write-Host "Installed signature file: $signatureTarget"
Write-Host 'In PixInsight, open Process > Modules > Install Modules and select this directory.'
