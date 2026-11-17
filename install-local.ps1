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
$keysDocument = Test-InDeSigningKeysDocument $keysFullPath
if (-not $keysDocument.Valid) {
    throw "The signing keys file is not usable: $($keysDocument.Reason) Regenerate it in PixInsight > Script > Development > SigningKeys."
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
$signingOutLog = Join-Path $signingDirectory 'pixinsight-sign.out.log'
$signingErrLog = Join-Path $signingDirectory 'pixinsight-sign.err.log'

try {
    New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourceDll -Destination $stageDll -Force

    $signingState = Get-InDePixInsightSigningState
    if (-not $signingState.LicenseFound) {
        throw 'PixInsight license data was not found in %APPDATA%\Pleiades. Activate a PixInsight license before installing InDe.'
    }
    if (-not $signingState.LocalSigningIdentityEnabled) {
        throw 'PixInsight has the local signing identity disabled. Enable it in Process > Preferences > Security and run setup again.'
    }
    if (-not $signingState.PersistentIdentity) {
        Write-Warning 'No persistent local signing identity was detected. Register your .xssk in PixInsight > Edit > Local Signing Identity and enable "Make the local signing identity persistent".'
    }

    Write-Host 'PixInsight will request the Local Signing Identity password.'
    Write-Host 'Enter the password in the PixInsight dialog. The installer does not read or store it.'

    $arguments = @(
        "--sign-module-file=`"$stageDll`"",
        "--xssk-file=`"$keysFullPath`""
    )
    # PixInsight reports command line signing failures on stderr and exits with
    # code -1. Some failures only show a modal "Fatal Error" window and keep
    # the process alive, so the window is watched and closed as well.
    $signingProcess = Start-Process -FilePath $pixInsightExe -ArgumentList $arguments `
        -RedirectStandardOutput $signingOutLog -RedirectStandardError $signingErrLog -PassThru
    $fatalWindow = [IntPtr]::Zero
    while (-not $signingProcess.HasExited) {
        Start-Sleep -Milliseconds 500
        if ($fatalWindow -ne [IntPtr]::Zero) { continue }
        $candidate = Find-InDePixInsightFatalErrorWindow $signingProcess.Id
        if ($candidate -ne [IntPtr]::Zero) {
            $fatalWindow = $candidate
            [void][InDeFatalWindowProbe]::Close($fatalWindow)
        }
    }
    $signingProcess.WaitForExit()
    $signingExitCode = $signingProcess.ExitCode
    if ($null -eq $signingExitCode) { $signingExitCode = -1 }
    $signingLogText = ''
    foreach ($logPath in @($signingOutLog, $signingErrLog)) {
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { continue }
        $logText = (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($logText)) { continue }
        if ([string]::IsNullOrWhiteSpace($signingLogText)) {
            $signingLogText = $logText
        }
        else {
            $signingLogText = $signingLogText + "`n" + $logText
        }
        if ([string]::IsNullOrWhiteSpace($signingLogText)) { $signingLogText = '' }
    }
    if ($signingExitCode -ne 0) {
        $logCopy = Copy-InDeDiagnosticLog $signingErrLog 'signing'
        if (-not $logCopy) { $logCopy = Copy-InDeDiagnosticLog $signingOutLog 'signing' }
        $detail = ''
        if (-not [string]::IsNullOrWhiteSpace($signingLogText)) {
            $detail = ($signingLogText -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' '
        }
        $crashed = ($signingExitCode -eq -1073740791) -or ($signingExitCode -eq -1073741819)
        $summary = if ($crashed) {
            "PixInsight crashed while signing the module (exit code $signingExitCode)."
        }
        elseif ($fatalWindow -ne [IntPtr]::Zero) {
            "PixInsight reported a fatal error while signing the module and closed its error window."
        }
        elseif ([string]::IsNullOrWhiteSpace($detail)) {
            "PixInsight signing did not complete. The signing password window was closed without signing the module."
        }
        else {
            "PixInsight signing failed with exit code $signingExitCode."
        }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'PixInsight produced no diagnostic output.' }
        throw ("$summary $detail" +
            "`nRegister a persistent local signing identity in PixInsight > Edit > Local Signing Identity, verify the .xssk password, and retry." +
            $(if ($logCopy) { "`nDiagnostic log: $logCopy" } else { '' }))
    }
    if (-not (Test-Path -LiteralPath $stageSignature -PathType Leaf)) {
        $logCopy = Copy-InDeDiagnosticLog $signingErrLog 'signing'
        if (-not $logCopy) { $logCopy = Copy-InDeDiagnosticLog $signingOutLog 'signing' }
        throw ("PixInsight did not generate InDe-pxm.xsgn." +
            $(if ($logCopy) { "`nDiagnostic log: $logCopy" } else { '' }))
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
