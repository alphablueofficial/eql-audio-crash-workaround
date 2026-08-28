[CmdletBinding()]
param(
    [ValidateSet('Launch', 'Check', 'Elevated', 'Recover', 'Watchdog', 'Probe')]
    [string]$Mode = 'Launch',
    [string]$LaunchPadPath = '',
    [ValidateRange(60, 3600)]
    [int]$LaunchTimeoutSeconds = 900,
    [ValidateRange(30, 1200)]
    [int]$InitializationTimeoutSeconds = 600,
    [string]$StatePath = '',
    [string]$ReadyPath = '',
    [string]$ExpectedScriptSha256 = '',
    [string]$TrustedSourcePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Version = '1.0.0-rc7'
$script:RegistrySubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$script:RegistryDisplayPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$script:RegistryValueName = 'midi'
$script:ExpectedValue = 'wdmaud.drv'
$script:ExpectedKind = 'String'
$script:GsSynthName = 'Microsoft GS Wavetable Synth'
$script:ApprovedLaunchPadSubject = 'CN=Daybreak Game Company LLC, OU=daybreak game company, O=Daybreak Game Company LLC, L=San Diego, S=California, C=US'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:BackupRoot = Join-Path $env:ProgramData 'EQL-GS-Synth-Workaround\Transactions'
$script:RuntimeRoot = Join-Path $env:ProgramData ('EQL-GS-Synth-Workaround\Runtime\' + $script:Version)
$script:SourcePath = if ($TrustedSourcePath) { [IO.Path]::GetFullPath($TrustedSourcePath) } else { $PSCommandPath }
$script:RuntimePath = $script:SourcePath
$script:RuntimeSha256 = ''
$script:LogFile = $null
$script:InstanceMutex = $null
$script:OwnsInstanceMutex = $false
$script:FinalResultWritten = $false
$script:LiveTransactionStarted = $false
$script:LiveRestorationVerified = $false

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine) } catch { }
    }
}

function Write-FinalResult {
    param([string]$Message, [string]$Level)
    $script:FinalResultWritten = $true
    Write-Status $Message $Level
}

function Write-LaunchResult {
    param([int]$ExitCode, [string]$Details = '')
    $suffix = if ([string]::IsNullOrWhiteSpace($Details)) { '' } else { ' Details: ' + $Details }
    switch ($ExitCode) {
        0 { Write-FinalResult 'SUCCESS - EQL reached character select and Windows MIDI was fully restored.' 'PASS' }
        2 { Write-FinalResult ('FAILED - EQL did not reach character select. Windows MIDI was fully restored.' + $suffix) 'ERROR' }
        3 { Write-FinalResult ('FAILED - Windows MIDI restoration could not be verified. Run Emergency Restore Windows MIDI.cmd.' + $suffix) 'ERROR' }
        default { Write-FinalResult 'STOPPED - The guarded run did not complete. No temporary change was confirmed; review the elevated error above.' 'ERROR' }
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enter-WorkaroundMutex {
    $createdNew = $false
    $script:InstanceMutex = New-Object Threading.Mutex($false, 'Global\EQLGSSynthWorkaround-v1', [ref]$createdNew)
    try {
        $script:OwnsInstanceMutex = $script:InstanceMutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $script:OwnsInstanceMutex = $true
    }
    if (-not $script:OwnsInstanceMutex) {
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
        throw 'Another EQL GS Synth workaround launch or recovery is already active.'
    }
}

function Exit-WorkaroundMutex {
    if ($script:InstanceMutex) {
        if ($script:OwnsInstanceMutex) {
            try { $script:InstanceMutex.ReleaseMutex() } catch { }
        }
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
        $script:OwnsInstanceMutex = $false
    }
}

function New-ProtectedDirectorySecurity {
    $administrators = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($administrators, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($system, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)))
    [void]$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize', $inheritance, $propagation, $allow)))
    return $security
}

function Initialize-ProtectedBackupRoot {
    if (-not (Test-IsAdministrator)) { throw 'Protected transaction storage requires administrator rights.' }
    $root = Join-Path $env:ProgramData 'EQL-GS-Synth-Workaround'
    $runtimeParent = Split-Path -Parent $script:RuntimeRoot
    foreach ($path in @($root, $script:BackupRoot, $runtimeParent, $script:RuntimeRoot)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw ('Refusing reparse-point transaction storage: ' + $path)
            }
            if (-not $item.PSIsContainer) { throw ('Transaction storage path is not a directory: ' + $path) }
            $existingSecurity = [IO.Directory]::GetAccessControl($path)
            $existingOwnerSid = $existingSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($existingOwnerSid -notin @('S-1-5-32-544', 'S-1-5-18')) {
                throw ('Refusing pre-existing transaction storage not owned by Administrators or SYSTEM: {0} (owner {1})' -f $path, $existingOwnerSid)
            }
        }
        else {
            [IO.Directory]::CreateDirectory($path) | Out-Null
        }

        $security = New-ProtectedDirectorySecurity
        [IO.Directory]::SetAccessControl($path, $security)

        $verified = Get-Item -LiteralPath $path -Force
        if ($verified.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw ('Transaction storage became a reparse point during initialization: ' + $path)
        }
        $verifiedSecurity = [IO.Directory]::GetAccessControl($path)
        $verifiedOwnerSid = $verifiedSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($verifiedOwnerSid -ne 'S-1-5-32-544') {
            throw ('Protected transaction storage has an unexpected owner SID: ' + $verifiedOwnerSid)
        }
    }
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return -join ($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $algorithm.Dispose() }
}

function Get-FileSha256 {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or $item.Length -le 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw ('Script is missing, empty, not regular, or a reparse point: ' + $Path)
    }
    $stream = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return -join ($algorithm.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Get-TrustedSourceBytes {
    $variable = Get-Variable -Name EqlAudioFixTrustedBytes -Scope Global -ErrorAction SilentlyContinue
    if ($variable -and $variable.Value -is [byte[]]) { return ,([byte[]]$variable.Value) }
    return $null
}

function Assert-ScriptIdentity {
    param([string]$Expected = '')
    $trustedBytes = Get-TrustedSourceBytes
    $actual = if ($trustedBytes) { Get-BytesSha256 $trustedBytes } else { Get-FileSha256 $script:SourcePath }
    if ($Expected -and ($Expected -notmatch '^[0-9a-fA-F]{64}$' -or
        -not $actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase))) {
        throw ('Script SHA-256 mismatch. Expected {0}; found {1}.' -f $Expected, $actual)
    }
    $script:RuntimePath = $script:SourcePath
    $script:RuntimeSha256 = $actual
    return $actual
}

function Write-BytesAtomic {
    param([string]$Path, [byte[]]$Bytes)
    $temporary = $Path + '.tmp-' + $PID
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    if (-not (Test-Path -LiteralPath $Path)) { [IO.File]::Move($temporary, $Path); return }
    $backup = $Path + '.replace-backup-' + $PID
    if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) }
    [IO.File]::Replace($temporary, $Path, $backup)
    if (Test-Path -LiteralPath $backup) { [IO.File]::Delete($backup) }
}

function Stage-ProtectedRuntimeScript {
    param([string]$Expected)
    if (-not (Test-IsAdministrator)) { throw 'Protected script staging requires administrator rights.' }
    $bytes = Get-TrustedSourceBytes
    if (-not $bytes) { throw 'Elevated mode did not receive hash-verified bootstrap bytes.' }
    $actual = Get-BytesSha256 $bytes
    if (-not $actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Trusted bootstrap bytes no longer match the expected hash.' }
    $destination = Join-Path $script:RuntimeRoot 'EQL-Audio-Fix.ps1'
    if (Test-Path -LiteralPath $destination) {
        $item = Get-Item -LiteralPath $destination -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Refusing reparse-point runtime script: ' + $destination) }
    }
    Write-BytesAtomic $destination $bytes
    $staged = Get-FileSha256 $destination
    if (-not $staged.Equals($actual, [StringComparison]::OrdinalIgnoreCase)) { throw 'Protected runtime staging hash mismatch.' }
    Remove-Variable -Name EqlAudioFixTrustedBytes -Scope Global -ErrorAction SilentlyContinue
    $script:RuntimePath = $destination
    $script:RuntimeSha256 = $staged
    return $destination
}

function Invoke-ElevatedCopy {
    param(
        [ValidateSet('Elevated', 'Recover')][string]$TargetMode,
        [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$EntrySha256
    )
    [void](Assert-ScriptIdentity $EntrySha256)
    $sourceHash = $EntrySha256.ToLowerInvariant()
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $sourceBase64 = [Convert]::ToBase64String($utf8.GetBytes($script:SourcePath))
    $launchPadBase64 = [Convert]::ToBase64String($utf8.GetBytes($LaunchPadPath))
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$utf8 = New-Object Text.UTF8Encoding(`$false, `$true)
`$source = `$utf8.GetString([Convert]::FromBase64String('$sourceBase64'))
`$launchPad = `$utf8.GetString([Convert]::FromBase64String('$launchPadBase64'))
`$bytes = [IO.File]::ReadAllBytes(`$source)
`$algorithm = [Security.Cryptography.SHA256]::Create()
try { `$actual = -join (`$algorithm.ComputeHash(`$bytes) | ForEach-Object { `$_.ToString('x2') }) }
finally { `$algorithm.Dispose() }
if (-not `$actual.Equals('$sourceHash', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source changed before elevated bootstrap verification.' }
`$global:EqlAudioFixTrustedBytes = `$bytes
`$text = `$utf8.GetString(`$bytes)
`$block = [ScriptBlock]::Create(`$text)
& `$block -Mode '$TargetMode' -ExpectedScriptSha256 '$sourceHash' -TrustedSourcePath `$source -LaunchPadPath `$launchPad -LaunchTimeoutSeconds $LaunchTimeoutSeconds -InitializationTimeoutSeconds $InitializationTimeoutSeconds
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    Write-Host 'Windows will ask for administrator approval for one temporary 64-bit registry value.'
    try {
        $process = Start-Process -FilePath $script:PowerShellExe -Verb RunAs -Wait -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
        return [int]$process.ExitCode
    }
    catch {
        Write-Host ('Administrator launch was cancelled or failed: ' + $_.Exception.Message) -ForegroundColor Red
        return 1223
    }
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $utf8 = New-Object Text.UTF8Encoding($false)
    Write-BytesAtomic $Path ($utf8.GetBytes(($Value | ConvertTo-Json -Depth 12)))
}

function Invoke-WithDrivers32 {
    param([bool]$Writable, [scriptblock]$Action)
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey($script:RegistrySubKey, $Writable)
        if ($null -eq $key) { throw 'The Windows Drivers32 registry key does not exist.' }
        return & $Action $key
    }
    finally {
        if ($key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function Get-RegistrySnapshot {
    return Invoke-WithDrivers32 $false {
        param($key)
        if ($key.GetValueNames() -notcontains $script:RegistryValueName) {
            return [ordered]@{ Present = $false; Value = $null; Kind = $null }
        }
        return [ordered]@{
            Present = $true
            Value = [string]$key.GetValue($script:RegistryValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind($script:RegistryValueName).ToString()
        }
    }
}

function Assert-ExpectedBaseline {
    param([object]$Snapshot)
    if (-not $Snapshot.Present) {
        throw ('The expected {0}\{1} value is absent. Nothing was changed.' -f $script:RegistryDisplayPath, $script:RegistryValueName)
    }
    if (-not ([string]$Snapshot.Value).Equals($script:ExpectedValue, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Unexpected Drivers32 value: expected {0}={1}, found {2}. Nothing was changed.' -f $script:RegistryValueName, $script:ExpectedValue, $Snapshot.Value)
    }
    if ([string]$Snapshot.Kind -ne $script:ExpectedKind) {
        throw ('Unexpected registry type: expected {0}, found {1}. Nothing was changed.' -f $script:ExpectedKind, $Snapshot.Kind)
    }
}

function Assert-WorkaroundState {
    param([object]$State)
    if ([string]$State.Schema -ne 'eql-gs-synth-workaround-state-v1') { throw 'State schema is not recognized.' }
    if ([string]$State.RegistryPath -ne $script:RegistryDisplayPath) { throw 'State registry path is not approved.' }
    if ([string]$State.RegistryView -ne 'Registry64') { throw 'State registry view is not approved.' }
    if ([string]$State.ValueName -ne $script:RegistryValueName) { throw 'State value name is not approved.' }
    if (-not [bool]$State.OriginalPresent) { throw 'State does not contain the required original value.' }
    if (-not ([string]$State.OriginalValue).Equals($script:ExpectedValue, [StringComparison]::OrdinalIgnoreCase)) { throw 'State original value is not approved.' }
    if ([string]$State.OriginalKind -ne $script:ExpectedKind) { throw 'State original registry type is not approved.' }
    if ([int]$State.ParentPid -le 0) { throw 'State parent PID is invalid.' }
    $parentStart = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$State.ParentStartTimeUtc, [ref]$parentStart)) { throw 'State parent start time is invalid.' }
    if ([int64]$State.DeadlineEpoch -le 0) { throw 'State deadline is invalid.' }
}

function Remove-GsSynthRegistration {
    Invoke-WithDrivers32 $true { param($key) $key.DeleteValue($script:RegistryValueName, $true) }
    if ((Get-RegistrySnapshot).Present) { throw 'The GS Synth registration remained after the temporary delete.' }
}

function Restore-GsSynthRegistration {
    param([object]$State)
    Assert-WorkaroundState $State
    $current = Get-RegistrySnapshot
    if ($current.Present) {
        if (([string]$current.Value).Equals($script:ExpectedValue, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$current.Kind -eq $script:ExpectedKind) { return }
        throw ('Refusing to overwrite a different Drivers32 midi value: {0} ({1}).' -f $current.Value, $current.Kind)
    }
    Invoke-WithDrivers32 $true {
        param($key)
        $key.SetValue($script:RegistryValueName, $script:ExpectedValue, [Microsoft.Win32.RegistryValueKind]::String)
    }
    Assert-ExpectedBaseline (Get-RegistrySnapshot)
}

function Get-MidiDevicesInProcess {
    if (-not ('EqlAudioFix.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace EqlAudioFix {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MIDIOUTCAPS {
            public ushort wMid; public ushort wPid; public uint vDriverVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
            public ushort wTechnology; public ushort wVoices; public ushort wNotes;
            public ushort wChannelMask; public uint dwSupport;
        }
        [DllImport("winmm.dll")] private static extern uint midiOutGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern uint midiOutGetDevCapsW(UIntPtr id, out MIDIOUTCAPS caps, uint size);
        public static object[] Enumerate() {
            var rows = new List<object>(); uint count = midiOutGetNumDevs();
            uint size = (uint)Marshal.SizeOf(typeof(MIDIOUTCAPS));
            for (uint i = 0; i < count; i++) {
                MIDIOUTCAPS caps; uint result = midiOutGetDevCapsW((UIntPtr)i, out caps, size);
                rows.Add(new { id = i, name = caps.szPname ?? "", result = result });
            }
            return rows.ToArray();
        }
    }
}
'@
    }
    return @([EqlAudioFix.NativeMethods]::Enumerate())
}

function Write-MidiProbeJson {
    if (-not [Environment]::Is64BitProcess) { throw 'MIDI probe requires 64-bit Windows PowerShell.' }
    [ordered]@{
        schema = 'eql-midi-probe-v1'
        processBitness = if ([Environment]::Is64BitProcess) { 64 } else { 32 }
        devices = @(Get-MidiDevicesInProcess)
    } | ConvertTo-Json -Depth 5 -Compress
}

function Invoke-MidiProbe {
    if (-not $script:RuntimeSha256) { throw 'Runtime script identity is not initialized.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:PowerShellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -Mode Probe -ExpectedScriptSha256 {1}' -f (Quote-ProcessArgument $script:RuntimePath), $script:RuntimeSha256
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        throw 'The fresh-process MIDI probe timed out.'
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw ('The fresh-process MIDI probe failed: ' + $stderr.Trim()) }
    try {
        $result = $stdout | ConvertFrom-Json
        if ([int]$result.processBitness -ne 64) { throw 'The MIDI probe did not run as a 64-bit process.' }
        return @($result.devices)
    }
    catch { throw ('The MIDI probe returned invalid output: ' + $_.Exception.Message) }
}

function Get-DeviceNames {
    param([object[]]$Devices)
    return @($Devices | ForEach-Object { [string]$_.name })
}

function Test-DeviceNameMultisetEqual {
    param([string[]]$Expected, [string[]]$Actual)
    if ($Expected.Count -ne $Actual.Count) { return $false }
    $remaining = New-Object Collections.Generic.List[string]
    foreach ($name in $Actual) { $remaining.Add([string]$name) }
    foreach ($expectedName in $Expected) {
        $found = -1
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            if ($remaining[$index].Equals($expectedName, [StringComparison]::OrdinalIgnoreCase)) {
                $found = $index
                break
            }
        }
        if ($found -lt 0) { return $false }
        $remaining.RemoveAt($found)
    }
    return $remaining.Count -eq 0
}

function Test-IsolationDelta {
    param([string[]]$Before, [string[]]$After)
    $expected = New-Object Collections.Generic.List[string]
    foreach ($name in $Before) { $expected.Add([string]$name) }
    $matches = @($expected | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1) { return $false }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($expected[$index].Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase)) {
            $expected.RemoveAt($index)
            break
        }
    }
    return Test-DeviceNameMultisetEqual -Expected @($expected) -Actual $After
}

function Export-Drivers32 {
    param([string]$Destination)
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    & $regExe export $script:RegistryDisplayPath $Destination /y /reg:64 | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw 'The 64-bit Drivers32 registry export failed. Nothing was changed.'
    }
}

function Test-LaunchPadCandidate {
    param([string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Candidate.Trim('"'))
    if (Test-Path -LiteralPath $expanded -PathType Container) {
        $expanded = Join-Path $expanded 'LaunchPad.exe'
    }
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) { return $null }
    if (-not ([IO.Path]::GetFileName($expanded)).Equals('LaunchPad.exe', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return [IO.Path]::GetFullPath($expanded)
}

function Assert-OfficialLaunchPad {
    param([string]$Path)
    $candidate = Test-LaunchPadCandidate $Path
    if (-not $candidate) { throw 'The selected file is not an existing LaunchPad.exe.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $candidate
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate) {
        throw ('LaunchPad signature is not valid: ' + $signature.Status.ToString())
    }
    $subject = [string]$signature.SignerCertificate.Subject
    if (-not $subject.Equals($script:ApprovedLaunchPadSubject, [StringComparison]::Ordinal)) {
        throw ('LaunchPad signer subject is not the exact approved Daybreak identity. Observed signer: ' + $subject)
    }
    $version = (Get-Item -LiteralPath $candidate).VersionInfo
    if ([string]$version.CompanyName -ne 'Daybreak Game Company' -or [string]$version.ProductName -ne 'LaunchPad') {
        throw ('LaunchPad version metadata is not approved. Company={0}; Product={1}' -f $version.CompanyName, $version.ProductName)
    }
    return [ordered]@{
        Path = $candidate
        SignerSubject = $subject
        SignerThumbprint = [string]$signature.SignerCertificate.Thumbprint
        CompanyName = [string]$version.CompanyName
        ProductName = [string]$version.ProductName
        FileVersion = [string]$version.FileVersion
    }
}

function Get-ProcessIntegrityRid {
    param([int]$ProcessId)
    if (-not ('EqlAudioFix.ProcessSecurity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace EqlAudioFix {
    public static class ProcessSecurity {
        [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returnLength);
        [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public static int GetIntegrityRid(int pid) {
            IntPtr process = OpenProcess(0x1000, false, pid), token = IntPtr.Zero, buffer = IntPtr.Zero;
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                if (!OpenProcessToken(process, 0x0008, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                int length; GetTokenInformation(token, 25, IntPtr.Zero, 0, out length);
                if (Marshal.GetLastWin32Error() != 122 || length <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                buffer = Marshal.AllocHGlobal(length);
                if (!GetTokenInformation(token, 25, buffer, length, out length)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var label = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(buffer, typeof(TOKEN_MANDATORY_LABEL));
                byte count = Marshal.ReadByte(GetSidSubAuthorityCount(label.Label.Sid));
                if (count == 0) throw new InvalidOperationException("Integrity SID has no subauthorities.");
                return Marshal.ReadInt32(GetSidSubAuthority(label.Label.Sid, (uint)(count - 1)));
            }
            finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (token != IntPtr.Zero) CloseHandle(token);
                CloseHandle(process);
            }
        }
    }
}
'@
    }
    return [EqlAudioFix.ProcessSecurity]::GetIntegrityRid($ProcessId)
}

function Assert-MediumIntegrityProcess {
    param([int]$ProcessId)
    $rid = Get-ProcessIntegrityRid $ProcessId
    if ($rid -lt 0x2000 -or $rid -ge 0x3000) {
        throw ('Process PID {0} is not running at normal medium integrity (RID 0x{1:X}).' -f $ProcessId, $rid)
    }
    return $rid
}

function Get-LaunchPadProcessRecords {
    $records = New-Object Collections.Generic.List[object]
    foreach ($process in Get-Process -Name LaunchPad -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = [string]$process.Path } catch { }
        $records.Add([pscustomobject]@{ Id = [int]$process.Id; Path = $path })
    }
    return $records.ToArray()
}

function Assert-MatchingLaunchPadRunning {
    param([string]$ApprovedPath)
    $records = @(Get-LaunchPadProcessRecords)
    if ($records.Count -ne 1) {
        throw ('Expected exactly one already-open official LaunchPad process; found {0}.' -f $records.Count)
    }
    if (-not ([string]$records[0].Path).Equals($ApprovedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('The open LaunchPad process path does not match the approved signed file: ' + [string]$records[0].Path)
    }
    $rid = Assert-MediumIntegrityProcess $records[0].Id
    return [pscustomobject]@{ Id = $records[0].Id; Path = $records[0].Path; IntegrityRid = $rid }
}

function Start-OrUseOfficialLaunchPad {
    param([string]$ApprovedPath)
    $records = @(Get-LaunchPadProcessRecords)
    if ($records.Count -gt 0) {
        return Assert-MatchingLaunchPadRunning $ApprovedPath
    }
    Start-Process -FilePath $ApprovedPath -WorkingDirectory (Split-Path -Parent $ApprovedPath) | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $records = @(Get-LaunchPadProcessRecords)
        if ($records.Count -eq 1 -and ([string]$records[0].Path).Equals($ApprovedPath, [StringComparison]::OrdinalIgnoreCase)) {
            return Assert-MatchingLaunchPadRunning $ApprovedPath
        }
        if ($records.Count -gt 0) {
            throw 'A LaunchPad process opened from a path other than the approved signed file.'
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'The approved signed LaunchPad did not open within 30 seconds.'
}

function Get-KnownLaunchPadCandidates {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
        foreach ($relative in @(
            'Daybreak Game Company\Installed Games\EverQuest Legends\LaunchPad.exe',
            'Program Files\Daybreak Game Company\Installed Games\EverQuest Legends\LaunchPad.exe',
            'Program Files (x86)\Daybreak Game Company\Installed Games\EverQuest Legends\LaunchPad.exe'
        )) {
            $candidate = Join-Path $drive.RootDirectory.FullName $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates.Add($candidate) }
        }
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($shortcutPath in @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'EverQuest Legends.lnk'),
            (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'EverQuest Legends.lnk')
        )) {
            if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $candidate = Test-LaunchPadCandidate ([string]$shortcut.TargetPath)
                if ($candidate) { $candidates.Add($candidate) }
            }
        }
    }
    catch { }
    return @($candidates | Select-Object -Unique)
}

function Select-LaunchPadInteractively {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select the official EverQuest Legends LaunchPad.exe'
    $dialog.Filter = 'LaunchPad.exe|LaunchPad.exe'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return Test-LaunchPadCandidate $dialog.FileName
}

function Resolve-LaunchPadPath {
    param([string]$ExplicitPath, [bool]$AllowPrompt)
    $candidate = Test-LaunchPadCandidate $ExplicitPath
    if ($candidate) { return $candidate }
    $known = @(Get-KnownLaunchPadCandidates)
    if ($known.Count -eq 1) { return $known[0] }
    if ($known.Count -gt 1) {
        if ($AllowPrompt) {
            Write-Status ('Found {0} possible EQL installations. Select the LaunchPad.exe you actually use.' -f $known.Count) 'WARN'
            return Select-LaunchPadInteractively
        }
        return $null
    }
    if ($AllowPrompt) { return Select-LaunchPadInteractively }
    return $null
}

function Get-CurrentRunLogSegment {
    param([string]$Path, [string]$BaselineText)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    [string]$current = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $current) { return '' }
    $baselineLength = if ($null -eq $BaselineText) { 0 } else { $BaselineText.Length }
    if ($baselineLength -gt 0 -and $current.Length -ge $baselineLength -and
        $current.StartsWith($BaselineText, [StringComparison]::Ordinal)) {
        return $current.Substring($baselineLength)
    }
    return $current
}

function Get-InitializationStatus {
    param([string]$Text)
    if ($Text -match 'Fatal error occurred in mainthread') { return 'Fatal' }
    if ($Text -match 'Starting char select\.|Initializing character select UI\.|Initialization complete') { return 'Ready' }
    if ($Text -match 'Sound Manager loaded ') { return 'SoundManager' }
    return 'Waiting'
}

function Wait-ForNewEqgame {
    param([int[]]$BaselinePids, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Status 'LaunchPad is open. Click PLAY normally; the workaround is waiting for the new eqgame.exe process.'
    while ((Get-Date) -lt $deadline) {
        $pids = @(Get-Process -Name eqgame -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
        $newPids = @($pids | Where-Object { $BaselinePids -notcontains $_ })
        if ($newPids.Count -gt 0) { return [int]($newPids | Sort-Object -Descending | Select-Object -First 1) }
        Start-Sleep -Milliseconds 250
    }
    throw ('Timed out after {0} seconds waiting for PLAY/eqgame.exe.' -f $TimeoutSeconds)
}

function Wait-ForEqlInitialization {
    param([int]$EqgamePid, [string]$DebugLogPath, [string]$BaselineLogText, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $soundReported = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $EqgamePid -ErrorAction SilentlyContinue)) {
            throw 'eqgame.exe exited before character-select initialization.'
        }
        $segment = Get-CurrentRunLogSegment $DebugLogPath $BaselineLogText
        $status = Get-InitializationStatus $segment
        if ($status -eq 'Fatal') { throw 'EQL logged the Release Client #630 fatal during initialization.' }
        if ($status -eq 'Ready') {
            Write-Status 'Character-select initialization detected. The workaround can now restore GS Synth.' 'PASS'
            return
        }
        if ($status -eq 'SoundManager' -and -not $soundReported) {
            Write-Status 'Sound Manager loaded; continuing to watch for character select or a delayed fatal.'
            $soundReported = $true
        }
        Start-Sleep -Milliseconds 250
    }
    throw ('Timed out after {0} seconds waiting for a current-run character-select marker.' -f $TimeoutSeconds)
}

function Start-RestorationWatchdog {
    param([string]$StatePath, [string]$Folder)
    if (-not (Test-Path -LiteralPath $script:RuntimePath -PathType Leaf)) { throw ('Runtime script is missing: ' + $script:RuntimePath) }
    $readyPath = Join-Path $Folder 'watchdog.ready.json'
    if (Test-Path -LiteralPath $readyPath) { [IO.File]::Delete($readyPath) }
    $arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -Mode Watchdog -StatePath {1} -ReadyPath {2} -ExpectedScriptSha256 {3}' -f
        (Quote-ProcessArgument $script:RuntimePath),
        (Quote-ProcessArgument $StatePath),
        (Quote-ProcessArgument $readyPath),
        $script:RuntimeSha256)
    $watchdogOptions = @{
        FilePath = $script:PowerShellExe
        ArgumentList = $arguments
        WindowStyle = 'Hidden'
        PassThru = $true
        RedirectStandardOutput = (Join-Path $Folder 'watchdog.stdout.log')
        RedirectStandardError = (Join-Path $Folder 'watchdog.stderr.log')
    }
    $process = Start-Process @watchdogOptions
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { throw ('Restoration watchdog exited before readiness with code ' + $process.ExitCode + '.') }
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            try {
                $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                if ([string]$ready.Schema -eq 'eql-gs-synth-watchdog-ready-v1' -and
                    [int]$ready.WatchdogPid -eq [int]$process.Id -and
                    ([string]$ready.StatePath).Equals([IO.Path]::GetFullPath($StatePath), [StringComparison]::OrdinalIgnoreCase) -and
                    ([string]$ready.ScriptSha256).Equals($script:RuntimeSha256, [StringComparison]::OrdinalIgnoreCase)) { return $process }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    try { $process.Kill() } catch { }
    throw 'Restoration watchdog did not acknowledge readiness within 10 seconds; no registry change was made.'
}

function Invoke-Watchdog {
    if (-not $StatePath -or -not $ReadyPath) { throw 'Watchdog state and ready paths are required.' }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-WorkaroundState $state
    $stateDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $StatePath)).TrimEnd('\')
    $readyDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $ReadyPath)).TrimEnd('\')
    if (-not $stateDirectory.Equals($readyDirectory, [StringComparison]::OrdinalIgnoreCase)) { throw 'Watchdog ready path must share the transaction directory.' }
    if ($state.PSObject.Properties['RuntimeScriptSha256'] -and [string]$state.RuntimeScriptSha256 -and
        -not ([string]$state.RuntimeScriptSha256).Equals($script:RuntimeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Watchdog state is bound to a different runtime script hash.'
    }
    Write-JsonAtomic $ReadyPath ([ordered]@{
        Schema = 'eql-gs-synth-watchdog-ready-v1'; WatchdogPid = $PID
        StatePath = [IO.Path]::GetFullPath($StatePath); ScriptSha256 = $script:RuntimeSha256
        ReadyAtUtc = [DateTime]::UtcNow.ToString('o')
    })
    while ($true) {
        $parentAlive = $false
        $parent = Get-Process -Id ([int]$state.ParentPid) -ErrorAction SilentlyContinue
        if ($parent) {
            try { $parentAlive = $parent.StartTime.ToUniversalTime().ToString('o') -eq [string]$state.ParentStartTimeUtc }
            catch { $parentAlive = $false }
        }
        $expired = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [int64]$state.DeadlineEpoch
        $inactive = $false
        try {
            $current = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            Assert-WorkaroundState $current
            $inactive = -not [bool]$current.Active
            $state = $current
        }
        catch { }
        if ($inactive -or -not $parentAlive -or $expired) { break }
        Start-Sleep -Seconds 1
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Restore-GsSynthRegistration $state
            $names = @(Get-DeviceNames @(Invoke-MidiProbe))
            if (-not ($names | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })) {
                throw 'GS Synth did not freshly enumerate after watchdog restoration.'
            }
            $state.Active = $false
            $state | Add-Member -NotePropertyName WatchdogRestored -NotePropertyValue $true -Force
            $state | Add-Member -NotePropertyName WatchdogRestoredAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            Write-JsonAtomic $StatePath $state
            Write-Output 'PASS: watchdog verified exact GS Synth restoration.'
            return
        }
        catch { $lastError = $_.Exception; Start-Sleep -Seconds 1 }
    }
    throw ('Watchdog could not verify GS Synth restoration: ' + $lastError.Message)
}

function Invoke-StaleRecovery {
    if (-not (Test-Path -LiteralPath $script:BackupRoot -PathType Container)) {
        Write-Status 'No backup folder exists; there are no recorded active transactions to recover.'
        return 0
    }
    $active = New-Object Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -LiteralPath $script:BackupRoot -Filter 'state.json' -File -Recurse -ErrorAction SilentlyContinue) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            Assert-WorkaroundState $state
            if ([bool]$state.Active) { $active.Add([pscustomobject]@{ File = $file; State = $state }) }
        }
        catch {
            Write-Status ('Ignored an invalid state file: ' + $file.FullName) 'WARN'
        }
    }
    if ($active.Count -eq 0) {
        Write-Status 'No recorded active transactions require recovery.'
        return 0
    }
    foreach ($entry in $active) {
        Write-Status ('Recovering recorded transaction: ' + $entry.File.DirectoryName) 'WARN'
        Restore-GsSynthRegistration $entry.State
        $entry.State.Active = $false
        $entry.State | Add-Member -NotePropertyName RecoveredByNextRun -NotePropertyValue $true -Force
        $entry.State | Add-Member -NotePropertyName RecoveredAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-JsonAtomic $entry.File.FullName $entry.State
    }
    $devices = @(Invoke-MidiProbe)
    $names = @(Get-DeviceNames $devices)
    if (-not ($names | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })) {
        throw 'Recovery wrote the registry value, but a fresh process still cannot enumerate Microsoft GS Wavetable Synth.'
    }
    Write-Status ('Recovered {0} transaction(s); GS Synth is registered and freshly enumerable.' -f $active.Count) 'PASS'
    return $active.Count
}

function Invoke-DryRun {
    param([ValidatePattern('^[0-9a-fA-F]{64}$')][string]$EntrySha256)
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'This workaround requires 64-bit Windows PowerShell on 64-bit Windows.' }
    $callerIntegrityRid = Assert-MediumIntegrityProcess $PID
    $scriptHash = Assert-ScriptIdentity $EntrySha256
    $launchPad = Resolve-LaunchPadPath $LaunchPadPath $false
    $launchPadDetails = if ($launchPad) { Assert-OfficialLaunchPad $launchPad } else { $null }
    $snapshot = Get-RegistrySnapshot
    Assert-ExpectedBaseline $snapshot
    $names = @(Get-DeviceNames @(Invoke-MidiProbe))
    $gsPresent = [bool]($names | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $gsPresent) { throw 'Microsoft GS Wavetable Synth is not freshly enumerable at baseline.' }
    [ordered]@{
        Schema = 'eql-gs-synth-workaround-dry-run-v1'; Version = $script:Version; Mutated = $false
        IsAdministrator = Test-IsAdministrator; CallerIntegrityRid = $callerIntegrityRid; LaunchPadPath = $launchPad; LaunchPadFound = [bool]$launchPad
        LaunchPadSignatureValid = [bool]$launchPadDetails
        LaunchPadSigner = if ($launchPadDetails) { $launchPadDetails.SignerSubject } else { $null }
        ScriptSha256 = $scriptHash; RegistryPath = $script:RegistryDisplayPath
        RegistryValueName = $script:RegistryValueName; RegistryValue = $snapshot.Value; RegistryKind = $snapshot.Kind
        GsSynthPresent = $gsPresent; MidiOutputs = $names
        EqgameRunning = [bool](Get-Process -Name eqgame -ErrorAction SilentlyContinue)
        LaunchPadRunning = [bool](Get-Process -Name LaunchPad -ErrorAction SilentlyContinue)
    } | ConvertTo-Json -Depth 6 | Write-Host
    if ($launchPad) { Write-Status 'Compatibility check passed. No registry, audio, game, service, or Wave Link state was changed.' 'PASS' }
    else { Write-Status 'Fault-path checks passed, but LaunchPad was not auto-detected. Launch mode will open a file picker.' 'WARN' }
}

function Invoke-LiveWorkaround {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'This workaround is only for 64-bit Windows.' }
    if (-not (Test-IsAdministrator)) { throw 'The live workaround is not running as administrator.' }
    if (Get-Process -Name eqgame -ErrorAction SilentlyContinue) { throw 'eqgame.exe is already running. Close EQL before using this launcher.' }
    Initialize-ProtectedBackupRoot
    [void](Stage-ProtectedRuntimeScript $ExpectedScriptSha256)
    [void](Invoke-StaleRecovery)

    $launchPad = Resolve-LaunchPadPath $LaunchPadPath $false
    if (-not $launchPad) { throw 'The approved official EverQuest Legends LaunchPad.exe path was not passed into the elevated phase.' }
    $launchPadDetails = Assert-OfficialLaunchPad $launchPad
    $launchPadProcess = Assert-MatchingLaunchPadRunning $launchPad
    $installDirectory = Split-Path -Parent $launchPad
    $debugLogPath = Join-Path $installDirectory 'Logs\dbg.txt'
    $baselineLogText = ''
    if (Test-Path -LiteralPath $debugLogPath -PathType Leaf) {
        $baselineLogText = [string](Get-Content -LiteralPath $debugLogPath -Raw -ErrorAction SilentlyContinue)
    }

    $snapshot = Get-RegistrySnapshot
    Assert-ExpectedBaseline $snapshot
    $beforeDevices = @(Invoke-MidiProbe)
    $beforeNames = @(Get-DeviceNames $beforeDevices)
    $gsCount = @($beforeNames | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) }).Count
    if ($gsCount -ne 1) { throw ('Expected exactly one Microsoft GS Wavetable Synth output; found {0}. Nothing was changed.' -f $gsCount) }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $transactionId = $stamp + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $folder = Join-Path $script:BackupRoot ('transaction-' + $transactionId)
    if (Test-Path -LiteralPath $folder) { throw ('Refusing an existing transaction folder: ' + $folder) }
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $script:LogFile = Join-Path $folder 'launcher.log'
    $statePath = Join-Path $folder 'state.json'
    $regExportPath = Join-Path $folder 'Drivers32-64.reg'
    Export-Drivers32 $regExportPath

    $deadlineSeconds = $LaunchTimeoutSeconds + $InitializationTimeoutSeconds + 300
    $state = [ordered]@{
        Schema = 'eql-gs-synth-workaround-state-v1'
        Version = $script:Version
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Active = $true
        ParentPid = $PID
        ParentStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        DeadlineEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $deadlineSeconds
        RegistryPath = $script:RegistryDisplayPath
        RegistryView = 'Registry64'
        ValueName = $script:RegistryValueName
        OriginalPresent = [bool]$snapshot.Present
        OriginalValue = [string]$snapshot.Value
        OriginalKind = [string]$snapshot.Kind
        RegistryExport = $regExportPath
        BaselineMidiOutputs = $beforeNames
        LaunchPadPath = $launchPad
        LaunchPadProcessId = [int]$launchPadProcess.Id
        LaunchPadSignerSubject = [string]$launchPadDetails.SignerSubject
        LaunchPadSignerThumbprint = [string]$launchPadDetails.SignerThumbprint
        LaunchPadFileVersion = [string]$launchPadDetails.FileVersion
        WatchdogPid = 0
        RuntimeScriptSha256 = $script:RuntimeSha256
        IsolatedMidiOutputs = @()
        IsolatedAtUtc = $null
        Outcome = 'pending'
        ParentRestored = $false
        RestoredAtUtc = $null
        RestoredMidiOutputs = @()
        WatchdogRestored = $false
        WatchdogRestoredAtUtc = $null
        RecoveredByNextRun = $false
        RecoveredAtUtc = $null
    }
    Assert-WorkaroundState $state
    Write-JsonAtomic $statePath $state
    $watchdog = Start-RestorationWatchdog $statePath $folder
    $state.WatchdogPid = [int]$watchdog.Id
    Write-JsonAtomic $statePath $state
    Write-Status ('Rollback backup and independent watchdog armed: ' + $folder)

    $restored = $false
    $outcome = 'failure'
    $operationError = $null
    try {
        $script:LiveTransactionStarted = $true
        Remove-GsSynthRegistration
        $isolatedDevices = @(Invoke-MidiProbe)
        $isolatedNames = @(Get-DeviceNames $isolatedDevices)
        if (-not (Test-IsolationDelta $beforeNames $isolatedNames)) {
            throw ('Fresh-process MIDI verification did not equal baseline minus only GS Synth. Before={0}; After={1}' -f ($beforeNames -join ', '), ($isolatedNames -join ', '))
        }
        $state.IsolatedMidiOutputs = $isolatedNames
        $state.IsolatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic $statePath $state
        Write-Status 'Microsoft GS Wavetable Synth is temporarily absent; every other MIDI output is unchanged.' 'PASS'
        Write-Status 'Wave Link, Windows audio defaults, services, game files, and MIDI drivers were not changed.'

        [void](Assert-OfficialLaunchPad $launchPad)
        [void](Assert-MatchingLaunchPadRunning $launchPad)
        $baselinePids = @(Get-Process -Name eqgame -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
        $eqgamePid = Wait-ForNewEqgame $baselinePids $LaunchTimeoutSeconds
        Write-Status ('Detected new eqgame.exe PID ' + $eqgamePid + '.')
        Wait-ForEqlInitialization $eqgamePid $debugLogPath $baselineLogText $InitializationTimeoutSeconds
        $outcome = 'success'
    }
    catch {
        $operationError = $_.Exception
    }
    finally {
        $lastRestoreError = $null
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            try {
                Restore-GsSynthRegistration $state
                $restoredDevices = @(Invoke-MidiProbe)
                $restoredNames = @(Get-DeviceNames $restoredDevices)
                if (-not (Test-DeviceNameMultisetEqual -Expected $beforeNames -Actual $restoredNames)) {
                    throw ('Fresh-process restoration verification did not exactly match the duplicate-aware baseline. Baseline={0}; Restored={1}' -f ($beforeNames -join ', '), ($restoredNames -join ', '))
                }
                $state.Active = $false
                $state.Outcome = $outcome
                $state.ParentRestored = $true
                $state.RestoredAtUtc = [DateTime]::UtcNow.ToString('o')
                $state.RestoredMidiOutputs = $restoredNames
                Write-JsonAtomic $statePath $state
                $restored = $true
                $script:LiveRestorationVerified = $true
                Write-Status 'Exact 64-bit midi=wdmaud.drv registration restored; GS Synth is freshly enumerable again.' 'PASS'
                break
            }
            catch {
                $lastRestoreError = $_.Exception
                Start-Sleep -Seconds 1
            }
        }
        if (-not $restored) {
            Write-LaunchResult 3 $folder
            Write-Status ('Restore error: ' + $lastRestoreError.Message) 'ERROR'
            Write-Status ('Leave this window open briefly; watchdog PID {0} will retry restoration when the parent exits or its deadline expires.' -f $state.WatchdogPid) 'ERROR'
            throw ('The parent could not verify GS Synth restoration: ' + $lastRestoreError.Message)
        }
    }

    if ($operationError) {
        Write-LaunchResult 2 $folder
        throw $operationError
    }
    Write-LaunchResult 0
}

$exitCode = 0
try {
    switch ($Mode) {
        'Probe' {
            [void](Assert-ScriptIdentity $ExpectedScriptSha256)
            Write-MidiProbeJson
        }
        'Watchdog' {
            [void](Assert-ScriptIdentity $ExpectedScriptSha256)
            Invoke-Watchdog
        }
        'Check' {
            if (-not (Get-TrustedSourceBytes)) { throw 'Check mode must start through the CMD bootstrap.' }
            $entrySha256 = Assert-ScriptIdentity $ExpectedScriptSha256
            Invoke-DryRun $entrySha256
        }
        'Recover' {
            if (-not (Test-IsAdministrator)) {
                if (-not (Get-TrustedSourceBytes)) { throw 'Recover mode must start through Emergency Restore Windows MIDI.cmd.' }
                $entrySha256 = Assert-ScriptIdentity $ExpectedScriptSha256
                $exitCode = Invoke-ElevatedCopy 'Recover' $entrySha256
                if ($exitCode -eq 0) { Write-FinalResult 'RECOVERY COMPLETE - No recorded active transaction remains.' 'PASS' }
                else { Write-FinalResult 'RECOVERY STOPPED - Windows MIDI recovery did not complete. Review the elevated error above.' 'ERROR' }
                break
            }
            if (-not (Get-TrustedSourceBytes)) { throw 'Recover mode requires the hash-verifying elevated bootstrap.' }
            [void](Assert-ScriptIdentity $ExpectedScriptSha256)
            Enter-WorkaroundMutex
            try {
                Initialize-ProtectedBackupRoot
                [void](Stage-ProtectedRuntimeScript $script:RuntimeSha256)
                $recovered = Invoke-StaleRecovery
                if ($recovered -gt 0) { Write-FinalResult ('RECOVERY COMPLETE - Restored {0} recorded transaction(s).' -f $recovered) 'PASS' }
                else { Write-FinalResult 'RECOVERY CHECK COMPLETE - No recorded active transaction required restoration.' 'PASS' }
            }
            finally { Exit-WorkaroundMutex }
        }
        'Elevated' {
            if (-not (Test-IsAdministrator)) { throw 'Elevated mode requires administrator rights.' }
            if (-not (Get-TrustedSourceBytes)) { throw 'Elevated mode requires the hash-verifying bootstrap.' }
            [void](Assert-ScriptIdentity $ExpectedScriptSha256)
            Enter-WorkaroundMutex
            try { Invoke-LiveWorkaround }
            finally { Exit-WorkaroundMutex }
        }
        'Launch' {
            if (Test-IsAdministrator) { throw 'Run the CMD launcher normally; it requests UAC only after opening LaunchPad.' }
            if (-not (Get-TrustedSourceBytes)) { throw 'Launch mode must start through Launch EQL Audio Fix.cmd.' }
            $entrySha256 = Assert-ScriptIdentity $ExpectedScriptSha256
            Invoke-DryRun $entrySha256
            if (Get-Process -Name eqgame -ErrorAction SilentlyContinue) { throw 'eqgame.exe is already running. Close EQL first.' }
            $approvedPath = Resolve-LaunchPadPath $LaunchPadPath $true
            if (-not $approvedPath) { throw 'The official EverQuest Legends LaunchPad.exe was not selected.' }
            [void](Assert-OfficialLaunchPad $approvedPath)
            $normalLaunchPad = Start-OrUseOfficialLaunchPad $approvedPath
            Write-Status ('Verified and opened signed Daybreak LaunchPad at medium integrity before UAC (PID {0}, RID 0x{1:X}).' -f $normalLaunchPad.Id, $normalLaunchPad.IntegrityRid) 'PASS'
            $LaunchPadPath = $approvedPath
            $exitCode = Invoke-ElevatedCopy 'Elevated' $entrySha256
            Write-LaunchResult $exitCode
        }
    }
}
catch {
    if ($Mode -in @('Probe', 'Watchdog')) { [Console]::Error.WriteLine($_.Exception.Message) }
    else {
        if ($script:FinalResultWritten) { Write-Status ('Reason: ' + $_.Exception.Message) 'ERROR' }
        else { Write-FinalResult ('STOPPED - ' + $_.Exception.Message) 'ERROR' }
    }
    if ($Mode -eq 'Elevated' -and $script:LiveTransactionStarted) {
        $exitCode = if ($script:LiveRestorationVerified) { 2 } else { 3 }
    }
    else { $exitCode = 1 }
}
exit $exitCode
