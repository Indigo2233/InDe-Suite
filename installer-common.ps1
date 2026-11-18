# Shared, non-interactive validation. Compatible with Windows PowerShell 5.1.
Set-StrictMode -Version 2.0

function Get-InDeFullPath {
    param([string]$Path)
    # Resolve relative arguments against PowerShell's location, which can differ
    # from the process working directory after Set-Location.
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Get-InDeExpectedHash {
    param([string]$Checksums, [string]$FileName)
    $found = @()
    foreach ($line in ($Checksums -split '\r?\n')) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -ceq $FileName) {
            $found += $Matches[1].ToLowerInvariant()
        }
    }
    if ($found.Count -ne 1) { throw "Expected exactly one checksum for $FileName." }
    return $found[0]
}

function Get-InDeChildPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':') -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Invalid package path: $RelativePath"
    }
    $rootFull = (Get-InDeFullPath $Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package path leaves its root: $RelativePath"
    }
    return $full
}

function Test-InDePackage {
    param([string]$PackageRoot)
    $manifestPath = Join-Path $PackageRoot 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.platform -ne 'windows-x64' -or @($manifest.files).Count -eq 0) {
        throw 'Unsupported or empty package manifest.'
    }
    $seen = @{}
    foreach ($entry in $manifest.files) {
        $path = Get-InDeChildPath $PackageRoot $entry.path
        if ($seen.ContainsKey($path)) { throw "Duplicate package path: $($entry.path)" }
        $seen[$path] = $true
        if ($entry.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Invalid or missing package file: $($entry.path)"
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) {
            throw "Package file checksum mismatch: $($entry.path). Download and extract the package again."
        }
    }
    foreach ($required in @('InDe-pxm.dll', 'install-local.ps1', 'installer-common.ps1',
        'InDeBackend/runtime/python.exe', 'InDeBackend/engine/run_models.py',
        'InDeBackend/tools/inde_worker.py', 'InDeBackend/engine/models/InDeConv.onnx',
        'InDeBackend/engine/models/InDeNoise.onnx', 'InDeBackend/engine/models/InDeStars.onnx',
        'test/native-selftest.js')) {
        if (-not $seen.ContainsKey((Get-InDeChildPath $PackageRoot $required))) {
            throw "Package manifest omits a required file: $required"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force) {
        if ($file.FullName -ine (Get-InDeFullPath $manifestPath) -and -not $seen.ContainsKey($file.FullName)) {
            throw "Unlisted package file: $($file.FullName). Extract a fresh package."
        }
    }
}

function Assert-InDeDestination {
    param([string]$Destination, [string]$PackageRoot, [string]$PixInsightRoot)
    $target = (Get-InDeFullPath $Destination).TrimEnd('\', '/')
    $drive = [IO.Path]::GetPathRoot($target).TrimEnd('\', '/')
    if ($target -eq $drive) { throw 'Choose a dedicated InDe installation directory.' }
    foreach ($protected in @($PackageRoot, $PixInsightRoot, $env:USERPROFILE, $env:LOCALAPPDATA, $env:ProgramFiles)) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        $protectedFull = (Get-InDeFullPath $protected).TrimEnd('\', '/')
        if ($target -ieq $protectedFull -or
            $protectedFull.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installation destination overlaps a protected directory: $target"
        }
    }
    $packageFull = (Get-InDeFullPath $PackageRoot).TrimEnd('\', '/')
    if ($target.StartsWith($packageFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation destination must be outside the downloaded package.'
    }
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Container)) {
        throw 'The installation destination must be a directory.'
    }
    if ((Test-Path -LiteralPath $target -PathType Container) -and
        @(Get-ChildItem -LiteralPath $target -Force).Count -gt 0 -and
        -not (Test-Path -LiteralPath (Join-Path $target 'InDe-pxm.dll') -PathType Leaf)) {
        throw 'This nonempty directory is not an existing InDe installation. Choose a dedicated directory.'
    }
}

function Get-InDePEMachine {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid Windows executable: $Path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt $stream.Length - 6) { throw 'Invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE signature.' }
        return $reader.ReadUInt16()
    }
    finally { $reader.Dispose() }
}

function Get-InDePixInsightSigningState {
    # Reports the local state PixInsight needs before it can sign a module.
    # Reads no .xssk content and no private key material.
    param()
    $applicationData = [Environment]::GetFolderPath('ApplicationData')
    $pleiades = Join-Path $applicationData 'Pleiades'
    $state = [pscustomobject]@{
        SettingsDirectory = $pleiades
        SettingsPath = ''
        SettingsPaths = @()
        SettingsFound = $false
        LicenseFound = $false
        PersistentIdentity = $false
        LocalSigningIdentityEnabled = $true
        DisabledSettingsPaths = @()
        PersistentSettingsPaths = @()
    }
    if (-not (Test-Path -LiteralPath $pleiades -PathType Container)) {
        return $state
    }
    $settings = @(Get-ChildItem -LiteralPath $pleiades -Filter 'core-*-pxi.settings' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime, Name -Descending)
    if ($settings.Count -gt 0) {
        $state.SettingsPaths = @($settings | ForEach-Object { $_.FullName })
        $state.SettingsPath = $state.SettingsPaths[0]
        $state.SettingsFound = $true
    }
    $state.LicenseFound = Test-Path -LiteralPath (Join-Path $pleiades 'PixInsightLicense') -PathType Leaf
    if (-not $state.SettingsFound) {
        return $state
    }
    foreach ($settingsPath in $state.SettingsPaths) {
        try {
            $settingsText = [IO.File]::ReadAllText($settingsPath)
        }
        catch {
            continue
        }
        $publicKeyMatch = [regex]::Match($settingsText, '(?s)LocalSigningIdentity.{0,400}?PublicKey" t="s">([^<]*)')
        if ($publicKeyMatch.Success -and -not [string]::IsNullOrWhiteSpace($publicKeyMatch.Groups[1].Value)) {
            $state.PersistentIdentity = $true
            $state.PersistentSettingsPaths += $settingsPath
        }
        $enabledMatch = [regex]::Match($settingsText, 'EnableLocalSigningIdentity" t="b" v="([^"]*)"')
        if ($enabledMatch.Success -and $enabledMatch.Groups[1].Value -eq 'false') {
            $state.DisabledSettingsPaths += $settingsPath
        }
    }
    if ($state.DisabledSettingsPaths.Count -eq $state.SettingsPaths.Count) {
        $state.LocalSigningIdentityEnabled = $false
    }
    return $state
}

function Copy-InDeDiagnosticLog {
    # Keeps a copy of an installer log so a failed run can be inspected later.
    param([string]$SourcePath, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return ''
    }
    try {
        $logDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'InDeInstaller\logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $destination = Join-Path $logDirectory ("inde-$Label-$stamp.log")
        Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
        return $destination
    }
    catch {
        return ''
    }
}

function Test-InDeSigningKeysDocument {
    # Checks that a .xssk file is present and has a plausible size.
    # The file content is never read, parsed or reported: a .xssk holds the
    # private key and must stay opaque to the installer. A truncated or
    # corrupted keys file is reported by PixInsight on stderr, and the
    # installer forwards that message.
    param([string]$Path)
    $result = [pscustomobject]@{
        Valid = $false
        Reason = ''
    }
    try {
        $info = Get-Item -LiteralPath $Path
    }
    catch {
        $result.Reason = 'The signing keys file could not be read.'
        return $result
    }
    if ($info.Length -lt 512) {
        $result.Reason = 'The signing keys file is too small to be a valid XSSK document.'
        return $result
    }
    $result.Valid = $true
    return $result
}

function Assert-InDeSigningPrerequisites {
    param([object]$State)
    if (-not $State.LicenseFound) {
        throw 'PixInsight license data was not found in %APPDATA%\Pleiades. Activate a PixInsight license before installing InDe.'
    }
    if (-not $State.LocalSigningIdentityEnabled) {
        throw 'PixInsight has the local signing identity disabled. Enable it in Process > Preferences > Security and run setup again.'
    }
    if (-not $State.PersistentIdentity) {
        throw 'No persistent local signing identity was detected. Register the selected .xssk in PixInsight > Edit > Local Signing Identity, enable "Make the local signing identity persistent", and exit PixInsight before running setup again.'
    }
}

function Test-InDeSignatureDocument {
    # Validates the generated XSGN without executing or loading the module.
    param([string]$Path)
    $result = [pscustomobject]@{
        Valid = $false
        Reason = ''
        DeveloperId = ''
        CreationTime = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = 'The signature file was not created.'
        return $result
    }
    try {
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $readerSettings)
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.Load($reader)
        }
        finally {
            $reader.Dispose()
        }
        $root = $document.DocumentElement
        if ($null -eq $root -or $root.LocalName -ne 'xsgn') {
            $result.Reason = 'The signature root element is not xsgn.'
            return $result
        }
        $signatures = @($root.SelectNodes("*[local-name()='Signature']"))
        if ($signatures.Count -ne 1) {
            $result.Reason = 'The signature must contain exactly one Signature element.'
            return $result
        }
        $signature = $signatures[0]
        $developerId = $signature.GetAttribute('developerId')
        if ([string]::IsNullOrWhiteSpace($developerId)) {
            $result.Reason = 'The signature has no developerId.'
            return $result
        }
        $codeSignature = $signature.SelectSingleNode("*[local-name()='CodeSignature']")
        if ($null -eq $codeSignature -or [string]::IsNullOrWhiteSpace($codeSignature.InnerText)) {
            $result.Reason = 'The signature has no CodeSignature value.'
            return $result
        }
        try {
            [void][Convert]::FromBase64String($codeSignature.InnerText.Trim())
        }
        catch {
            $result.Reason = 'The signature CodeSignature value is not valid Base64.'
            return $result
        }
        $creationTime = $root.SelectSingleNode("*[local-name()='CreationTime']")
        $result.DeveloperId = $developerId
        $result.CreationTime = if ($null -eq $creationTime) { '' } else { $creationTime.InnerText.Trim() }
        $result.Valid = $true
        return $result
    }
    catch {
        $result.Reason = 'The signature document could not be parsed: ' + $_.Exception.Message
        return $result
    }
}

function Find-InDePixInsightFatalErrorWindow {
    # Finds the PixInsight "Fatal Error" modal window of a given process.
    # PixInsight shows this window for signing failures it cannot report on
    # stderr, and it blocks the process until a user closes it.
    param([int]$ProcessId)
    if ($null -eq ('InDeFatalWindowProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class InDeFatalWindowProbe {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  public static IntPtr Find(int processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      uint owner;
      GetWindowThreadProcessId(h, out owner);
      if (owner != (uint)processId) return true;
      StringBuilder title = new StringBuilder(256);
      GetWindowText(h, title, 256);
      string text = title.ToString();
      if (text.IndexOf("Fatal Error", StringComparison.OrdinalIgnoreCase) >= 0) {
        found = h;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static void Close(IntPtr h) {
    PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
  }
}
'@
    }
    return [InDeFatalWindowProbe]::Find($ProcessId)
}

