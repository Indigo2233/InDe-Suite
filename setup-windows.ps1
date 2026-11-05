[CmdletBinding()]
param(
    [ValidatePattern('^v\d+\.\d+\.\d+-local$')]
    [string]$ReleaseTag = 'v1.0.2-local',
    [string]$PackageDirectory,
    [string]$PixInsightRoot,
    [string]$KeysFile,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\InDe'),
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'installer-common.ps1')
$guide = 'https://github.com/Indigo2233/InDe-Suite/blob/main/docs/INSTALL.zh-CN.md'
$preferencesPath = Join-Path $env:LOCALAPPDATA 'InDeInstaller\preferences.json'

function Select-InDeFile {
    param([string]$Title, [string]$Filter)
    $dialog = New-Object Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = $Title
        $dialog.Filter = $Filter
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Setup cancelled.' }
        return $dialog.FileName
    }
    finally { $dialog.Dispose() }
}

function Show-InDeMessage {
    param([string]$Message, [Windows.Forms.MessageBoxButtons]$Buttons = 'OK')
    return [Windows.Forms.MessageBox]::Show($Message, 'InDe-Suite Setup', $Buttons, 'Information')
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'This installer requires 64-bit Windows. macOS packages are not yet available.'
    }
    if ($CheckOnly) {
        if ([string]::IsNullOrWhiteSpace($PackageDirectory)) { throw '-CheckOnly requires -PackageDirectory.' }
        Test-InDePackage $PackageDirectory
        if (-not [string]::IsNullOrWhiteSpace($PixInsightRoot)) {
            if ((Get-InDePEMachine (Join-Path $PixInsightRoot 'bin\PixInsight.exe')) -ne 0x8664) {
                throw 'This package requires an x64 PixInsight executable.'
            }
        }
        Assert-InDeDestination $Destination $PackageDirectory $PixInsightRoot
        Write-Host 'Package hashes, required files and destination checks passed. No installation was performed.'
        exit 0
    }
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Application]::EnableVisualStyles()

    if (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $PixInsightRoot -and $saved.PSObject.Properties['pixInsightRoot']) { $PixInsightRoot = $saved.pixInsightRoot }
            if (-not $KeysFile -and $saved.PSObject.Properties['keysFile']) { $KeysFile = $saved.keysFile }
        }
        catch { Write-Warning 'Saved paths could not be read. Select them again.' }
    }
    if (-not $PixInsightRoot) { $PixInsightRoot = Join-Path $env:ProgramFiles 'PixInsight' }
    if (-not (Test-Path -LiteralPath (Join-Path $PixInsightRoot 'bin\PixInsight.exe') -PathType Leaf)) {
        $exe = Select-InDeFile 'Select PixInsight.exe in the PixInsight bin directory' 'PixInsight executable|PixInsight.exe'
        $PixInsightRoot = Split-Path -Parent (Split-Path -Parent $exe)
    }
    $pixInsightExe = Join-Path $PixInsightRoot 'bin\PixInsight.exe'
    if ((Get-InDePEMachine $pixInsightExe) -ne 0x8664) { throw 'This release requires x64 PixInsight.' }

    $choice = Show-InDeMessage @'
Do you already have a .xssk file AND have you registered it in
PixInsight > Edit > Local Signing Identity (persistent)?

Yes: select/use your existing keys file.
No: open the detailed step-by-step instructions in your browser.
Cancel: leave setup.

Create and register keys in PixInsight. Enter passwords only in PixInsight.
'@ 'YesNoCancel'
    if ($choice -eq 'Cancel') { exit 0 }
    if ($choice -eq 'No') {
        $KeysFile = ''
        Start-Process $guide
        Show-InDeMessage @'
In PixInsight:
1. Script > Development > SigningKeys.
2. Select Generate Signing Keys and Local signing identity.
3. Output: choose local.xssk and set its password. Click Run.
4. Edit > Local Signing Identity: select that file and enter its password.
5. Enable Make the local signing identity persistent and confirm.

Keep the full keys path ASCII-only. Reuse an existing identity when available.
When ready, click OK to select the keys file.
'@ | Out-Null
    }
    if (-not $KeysFile -or -not (Test-Path -LiteralPath $KeysFile -PathType Leaf)) {
        $KeysFile = Select-InDeFile 'Select your local signing keys file' 'PixInsight signing keys|*.xssk'
    }
    $KeysFile = (Resolve-Path -LiteralPath $KeysFile).Path
    if ($KeysFile -match '[^\x00-\x7F]' -or [IO.Path]::GetExtension($KeysFile) -ine '.xssk') {
        throw 'Select a .xssk file whose full path contains ASCII characters only. See the installation guide.'
    }
    while (Get-Process PixInsight -ErrorAction SilentlyContinue) {
        if ((Show-InDeMessage 'Save your work and close all PixInsight windows, then click Retry. Setup will not close them for you.' 'RetryCancel') -eq 'Cancel') { exit 0 }
    }

    if (-not $PackageDirectory -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'package-manifest.json'))) {
        $PackageDirectory = $PSScriptRoot
    }
    if (-not $PackageDirectory) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $version = $ReleaseTag.Substring(1) -replace '-local$', ''
        $archiveName = "InDe-$version-local-windows-x64.zip"
        $baseUrl = "https://github.com/Indigo2233/InDe-Suite/releases/download/$ReleaseTag"
        $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('InDeSetup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $downloadRoot | Out-Null
        $checksumPath = Join-Path $downloadRoot 'SHA256SUMS-local.txt'
        $archivePath = Join-Path $downloadRoot $archiveName
        Write-Host "Downloading $ReleaseTag (approximately 390 MiB). Please keep this window open."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS-local.txt" -OutFile $checksumPath
        $expected = Get-InDeExpectedHash (Get-Content -LiteralPath $checksumPath -Raw) $archiveName
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName" -OutFile $archivePath
        if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $expected) {
            throw 'Download checksum mismatch. No package code was executed. Run setup again.'
        }
        $PackageDirectory = Join-Path $downloadRoot 'package'
        Write-Host 'Download verified. Extracting the package...'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $PackageDirectory
        Write-Host "Downloaded package retained for retry/offline installation: $downloadRoot"
    }
    Write-Host 'Verifying installed-package inputs...'
    Test-InDePackage $PackageDirectory
    Assert-InDeDestination $Destination $PackageDirectory $PixInsightRoot
    & (Join-Path $PackageDirectory 'install-local.ps1') -KeysFile $KeysFile -PixInsightRoot $PixInsightRoot -Destination $Destination

    New-Item -ItemType Directory -Path (Split-Path -Parent $preferencesPath) -Force | Out-Null
    @{ pixInsightRoot = $PixInsightRoot; keysFile = $KeysFile } |
        ConvertTo-Json | Set-Content -LiteralPath $preferencesPath -Encoding UTF8
    Write-Host "Saved installation paths: $preferencesPath"
    if ((Show-InDeMessage "Files installed and module signed.`n`nOpen PixInsight now?`nProcess > Modules > Install Modules`nSelect: $Destination`nClick Search, select InDe, then Install. Restart PixInsight.`n`nTest script: $Destination\test\native-selftest.js" 'YesNo') -eq 'Yes') {
        Start-Process -FilePath $pixInsightExe
    }
}
catch {
    Write-Host ("Setup stopped: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Instructions: $guide"
    exit 1
}
