# Tests use disposable files only. No PixInsight UI, keys, network or installed files.
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'installer-common.ps1')

function Expect-Failure {
    param([scriptblock]$Action, [string]$Expected)
    $caught = $false
    try { & $Action }
    catch {
        $caught = $true
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
    }
    if (-not $caught) { throw "Expected failure containing: $Expected" }
}

function New-SigningState {
    param(
        [bool]$PersistentIdentity,
        [bool]$LocalSigningIdentityEnabled = $true,
        [string[]]$PersistentSettingsPaths = @(),
        [string[]]$DisabledSettingsPaths = @(),
        [string[]]$SettingsPaths = @('first.settings')
    )
    if ($PersistentIdentity -and $PersistentSettingsPaths.Count -eq 0) {
        $PersistentSettingsPaths = @($SettingsPaths[-1])
    }
    return [pscustomobject]@{
        LicenseFound = $true
        LocalSigningIdentityEnabled = $LocalSigningIdentityEnabled
        PersistentIdentity = $PersistentIdentity
        SettingsPaths = $SettingsPaths
        PersistentSettingsPaths = $PersistentSettingsPaths
        DisabledSettingsPaths = $DisabledSettingsPaths
    }
}

# Parse all installer/packaging scripts with the actual interpreter running this test.
foreach ($file in Get-ChildItem -LiteralPath $repository -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
}

$hash = 'a' * 64
$text = "$hash  complete.zip`r`n$('b' * 64)  setup.zip`r`n"
if ((Get-InDeExpectedHash $text 'complete.zip') -cne $hash) { throw 'Wrong checksum selected.' }
Expect-Failure { Get-InDeExpectedHash $text 'missing.zip' } 'exactly one'
Expect-Failure { Get-InDeExpectedHash ($text + "$hash  complete.zip") 'complete.zip' } 'exactly one'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('inde-installer-test-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $fixture 'package with spaces'
New-Item -ItemType Directory -Path $package -Force | Out-Null
try {
    $files = @('InDe-pxm.dll', 'install-local.ps1', 'installer-common.ps1',
        'InDeBackend/runtime/python.exe', 'InDeBackend/engine/run_models.py',
        'InDeBackend/tools/inde_worker.py', 'InDeBackend/engine/models/InDeConv.onnx',
        'InDeBackend/engine/models/InDeNoise.onnx', 'InDeBackend/engine/models/InDeStars.onnx',
        'test/native-selftest.js')
    $entries = @()
    foreach ($relative in $files) {
        $path = Get-InDeChildPath $package $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'disposable installer test fixture')
        $entries += @{ path = $relative; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    $manifest = @{ schema = 1; platform = 'windows-x64'; files = $entries }
    $manifestPath = Join-Path $package 'package-manifest.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Test-InDePackage $package
    Push-Location $fixture
    try {
        Test-InDePackage '.\package with spaces'
        if ((Get-InDeChildPath '.\package with spaces' 'InDe-pxm.dll') -ine (Join-Path $package 'InDe-pxm.dll')) {
            throw 'Relative package path resolved outside the PowerShell location.'
        }
    }
    finally { Pop-Location }
    $extraFile = Join-Path $package 'unexpected.py'
    [IO.File]::WriteAllText($extraFile, 'unexpected')
    Expect-Failure { Test-InDePackage $package } 'Unlisted package file'
    Remove-Item -LiteralPath $extraFile
    $tampered = Join-Path $package 'InDeBackend/engine/models/InDeConv.onnx'
    [IO.File]::WriteAllText($tampered, 'tampered')
    Expect-Failure { Test-InDePackage $package } 'checksum mismatch'
    [IO.File]::WriteAllText($tampered, 'disposable installer test fixture')
    $manifest.files = $entries[1..($entries.Count - 1)]
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Expect-Failure { Test-InDePackage $package } 'omits a required file'
    foreach ($bad in @('..\escape', 'C:\escape', '/absolute', 'dir/../../escape', 'file:stream')) {
        Expect-Failure { Get-InDeChildPath $package $bad } 'Invalid package path'
    }
    Assert-InDeDestination (Join-Path $fixture 'install') $package 'C:\Program Files\PixInsight'
    Expect-Failure { Assert-InDeDestination $package $package 'C:\Program Files\PixInsight' } 'protected'
    Expect-Failure { Assert-InDeDestination $fixture $package 'C:\Program Files\PixInsight' } 'protected'
    Expect-Failure { Assert-InDeDestination (Join-Path $package 'nested') $package '' } 'outside'
    Expect-Failure { Assert-InDeDestination 'C:\' $package '' } 'dedicated'
    $unknown = Join-Path $fixture 'unrelated'
    New-Item -ItemType Directory -Path $unknown | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown 'user-data.txt'), 'preserve')
    Expect-Failure { Assert-InDeDestination $unknown $package '' } 'nonempty'
    Expect-Failure { Get-InDePEMachine $tampered } 'Invalid Windows executable'

    # Signing keys document validation: rejects files that make the PixInsight
    # command line signing call terminate with a fatal error.
    $keysDirectory = Join-Path $fixture 'keys'
    New-Item -ItemType Directory -Path $keysDirectory -Force | Out-Null
    $emptyKeys = Join-Path $keysDirectory 'empty.xssk'
    [IO.File]::WriteAllText($emptyKeys, '')
    $emptyResult = Test-InDeSigningKeysDocument $emptyKeys
    if ($emptyResult.Valid) { throw 'An empty signing keys file must be rejected.' }
    if ($emptyResult.Reason -notlike '*small*') { throw 'Unexpected reason for an empty signing keys file.' }

    # A truncated keys file must be rejected before PixInsight is started.
    $truncatedKeys = Join-Path $keysDirectory 'truncated.xssk'
    [IO.File]::WriteAllText($truncatedKeys, '<xssk version="1.0"><KeyPair>')
    $truncatedResult = Test-InDeSigningKeysDocument $truncatedKeys
    if ($truncatedResult.Valid) { throw 'A truncated signing keys file must be rejected.' }

    # The validator must never read the keys content.
    $goodKeys = Join-Path $keysDirectory 'good.xssk'
    [IO.File]::WriteAllText($goodKeys, ('x' * 2048))
    $goodResult = Test-InDeSigningKeysDocument $goodKeys
    if (-not $goodResult.Valid) { throw "A plausible signing keys file must be accepted: $($goodResult.Reason)" }

    $signatureText = @'
<?xml version="1.0" encoding="UTF-8"?>
<xsgn version="1.0" xmlns="http://www.pixinsight.com/xsgn">
  <CreationTime>2026-11-18T12:00:00.000Z</CreationTime>
  <Signature version="1.0" developerId="local-test">
    <Timestamp>2026-11-18T12:00:00.000Z</Timestamp>
    <CodeSignature encoding="Base64">ZGlzcG9zYWJsZQ==</CodeSignature>
  </Signature>
</xsgn>
'@
    $signaturePath = Join-Path $keysDirectory 'good.xsgn'
    [IO.File]::WriteAllText($signaturePath, $signatureText)
    $signatureResult = Test-InDeSignatureDocument $signaturePath
    if (-not $signatureResult.Valid) { throw "A valid signature fixture must be accepted: $($signatureResult.Reason)" }
    if ($signatureResult.DeveloperId -cne 'local-test') { throw 'The signature developer ID was not parsed.' }

    $badSignaturePath = Join-Path $keysDirectory 'bad.xsgn'
    [IO.File]::WriteAllText($badSignaturePath, $signatureText.Replace('ZGlzcG9zYWJsZQ==', 'not base64'))
    $badSignatureResult = Test-InDeSignatureDocument $badSignaturePath
    if ($badSignatureResult.Valid) { throw 'A signature with invalid Base64 must be rejected.' }

    # The signing state probe must not fail when no PixInsight data exists.
    $signingState = Get-InDePixInsightSigningState
    if ($null -eq $signingState) { throw 'The signing state probe returned nothing.' }
    if ($signingState.PSObject.Properties['PersistentIdentity'] -eq $null) { throw 'The signing state probe lacks the identity flag.' }

    $validPrerequisites = New-SigningState -PersistentIdentity $true
    Assert-InDeSigningPrerequisites $validPrerequisites
    $multiVersionState = New-SigningState -PersistentIdentity $true `
        -SettingsPaths @('old.settings', 'current.settings') `
        -PersistentSettingsPaths @('current.settings') `
        -DisabledSettingsPaths @('old.settings')
    Assert-InDeSigningPrerequisites $multiVersionState
    $allDisabledState = New-SigningState -PersistentIdentity $true `
        -LocalSigningIdentityEnabled $false `
        -SettingsPaths @('old.settings', 'current.settings') `
        -PersistentSettingsPaths @('current.settings') `
        -DisabledSettingsPaths @('old.settings', 'current.settings')
    Expect-Failure { Assert-InDeSigningPrerequisites $allDisabledState } 'disabled'
    $disabledWithoutIdentity = New-SigningState -PersistentIdentity $false `
        -LocalSigningIdentityEnabled $false `
        -SettingsPaths @('old.settings', 'current.settings') `
        -DisabledSettingsPaths @('old.settings', 'current.settings')
    Expect-Failure { Assert-InDeSigningPrerequisites $disabledWithoutIdentity } 'disabled'
    $missingPersistent = New-SigningState -PersistentIdentity $false
    Expect-Failure { Assert-InDeSigningPrerequisites $missingPersistent } 'No persistent local signing identity'

    $installerTokens = $null
    $installerErrors = $null
    $installerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repository 'install-local.ps1'), [ref]$installerTokens, [ref]$installerErrors)
    if ($installerErrors.Count -gt 0) { throw ($installerErrors | Out-String) }
    $installerCommands = @($installerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true))
    $prerequisiteCommand = $installerCommands |
        Where-Object { $_.GetCommandName() -eq 'Assert-InDeSigningPrerequisites' } |
        Select-Object -First 1
    $signingCommand = $installerCommands |
        Where-Object { $_.GetCommandName() -eq 'Start-Process' } |
        Select-Object -First 1
    if ($null -eq $prerequisiteCommand) { throw 'install-local.ps1 does not check signing prerequisites.' }
    if ($null -eq $signingCommand) { throw 'install-local.ps1 does not start PixInsight signing.' }
    if ($prerequisiteCommand.Extent.StartOffset -ge $signingCommand.Extent.StartOffset) {
        throw 'install-local.ps1 must check signing prerequisites before starting PixInsight.'
    }
    $continueCommand = $installerCommands |
        Where-Object { $_.GetCommandName() -eq 'Write-Warning' } |
        Where-Object { $_.Extent.Text -like '*valid signature before exiting*' } |
        Select-Object -First 1
    if ($null -eq $continueCommand) { throw 'install-local.ps1 does not handle post-signing crashes.' }
    $guard = $continueCommand.Parent
    while ($null -ne $guard -and $guard.Extent.Text -notlike '*$signingCrashed*') {
        $guard = $guard.Parent
    }
    if ($null -eq $guard) {
        throw 'install-local.ps1 must continue after a signature only for a recognized PixInsight crash.'
    }

    Write-Host "Installer smoke tests passed (PowerShell $($PSVersionTable.PSVersion))."
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'inde-installer-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
