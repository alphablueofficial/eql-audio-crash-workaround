[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$RecoverOnly,
    [switch]$SelfTest,
    [string]$LaunchPadPath = '',
    [ValidateRange(60, 3600)]
    [int]$LaunchTimeoutSeconds = 900,
    [ValidateRange(30, 1200)]
    [int]$InitializationTimeoutSeconds = 600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Version = '1.0.0-rc1'
$script:RegistrySubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$script:RegistryDisplayPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$script:RegistryValueName = 'midi'
$script:ExpectedValue = 'wdmaud.drv'
$script:ExpectedKind = 'String'
$script:GsSynthName = 'Microsoft GS Wavetable Synth'
$script:ApprovedLaunchPadSubject = 'CN=Daybreak Game Company LLC, OU=daybreak game company, O=Daybreak Game Company LLC, L=San Diego, S=California, C=US'
$script:PackageRoot = $PSScriptRoot
$script:SourceProbePath = Join-Path $PSScriptRoot 'EQL-Midi-Probe.ps1'
$script:SourceWatchdogPath = Join-Path $PSScriptRoot 'EQL-GS-Synth-Watchdog.ps1'
$script:ExpectedProbeSha256 = 'cc50e17da5ab37cc67c7ec6a85df2b36cd596055230f8c0299353e39a189995f'
$script:ExpectedWatchdogSha256 = '1d6cbf0dab110af189ecf55e31ea21725f55d50b3a2a06fee8f0c51875c2cdd0'
$script:ProbePath = $script:SourceProbePath
$script:WatchdogPath = $script:SourceWatchdogPath
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'EQL-GS-Synth-Workaround'
$script:ConfigPath = Join-Path $script:DataRoot 'config.json'
$script:BackupRoot = Join-Path $env:ProgramData 'EQL-GS-Synth-Workaround\Transactions'
$script:RuntimeRoot = Join-Path $env:ProgramData ('EQL-GS-Synth-Workaround\Runtime\' + $script:Version)
$script:LogFile = $null
$script:InstanceMutex = $null
$script:OwnsInstanceMutex = $false

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine) } catch { }
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

function Get-FileSha256 {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw ('Refusing a reparse-point helper file: ' + $Path)
    }
    if (-not $item.PSIsContainer -and $item.Length -gt 0) {
        $stream = $null
        $algorithm = $null
        try {
            $stream = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $algorithm = [Security.Cryptography.SHA256]::Create()
            $bytes = $algorithm.ComputeHash($stream)
            return -join ($bytes | ForEach-Object { $_.ToString('x2') })
        }
        finally {
            if ($algorithm) { $algorithm.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    throw ('Helper file is missing, empty, or not a regular file: ' + $Path)
}

function Assert-HelperSourceIntegrity {
    $actualProbe = Get-FileSha256 $script:SourceProbePath
    $actualWatchdog = Get-FileSha256 $script:SourceWatchdogPath
    if ($actualProbe -ne $script:ExpectedProbeSha256) {
        throw ('MIDI probe hash mismatch. Expected {0}; found {1}.' -f $script:ExpectedProbeSha256, $actualProbe)
    }
    if ($actualWatchdog -ne $script:ExpectedWatchdogSha256) {
        throw ('Watchdog hash mismatch. Expected {0}; found {1}.' -f $script:ExpectedWatchdogSha256, $actualWatchdog)
    }
    return [ordered]@{ Probe = $actualProbe; Watchdog = $actualWatchdog }
}

function Stage-ProtectedRuntimeHelpers {
    if (-not (Test-IsAdministrator)) { throw 'Protected helper staging requires administrator rights.' }
    $hashes = Assert-HelperSourceIntegrity
    foreach ($entry in @(
        [pscustomobject]@{ Source = $script:SourceProbePath; Destination = (Join-Path $script:RuntimeRoot 'EQL-Midi-Probe.ps1'); Expected = $hashes.Probe },
        [pscustomobject]@{ Source = $script:SourceWatchdogPath; Destination = (Join-Path $script:RuntimeRoot 'EQL-GS-Synth-Watchdog.ps1'); Expected = $hashes.Watchdog }
    )) {
        if (Test-Path -LiteralPath $entry.Destination) {
            $existing = Get-Item -LiteralPath $entry.Destination -Force
            if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw ('Refusing a reparse-point staged helper: ' + $entry.Destination)
            }
        }
        $bytes = [IO.File]::ReadAllBytes($entry.Source)
        $temporary = $entry.Destination + '.tmp-' + $PID
        [IO.File]::WriteAllBytes($temporary, $bytes)
        if (Test-Path -LiteralPath $entry.Destination) {
            $replaceBackup = $entry.Destination + '.replace-backup-' + $PID
            if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) }
            [IO.File]::Replace($temporary, $entry.Destination, $replaceBackup)
            if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) }
        }
        else {
            [IO.File]::Move($temporary, $entry.Destination)
        }
        $stagedHash = Get-FileSha256 $entry.Destination
        if ($stagedHash -ne [string]$entry.Expected) {
            throw ('Protected helper staging hash mismatch: ' + $entry.Destination)
        }
    }
    $script:ProbePath = Join-Path $script:RuntimeRoot 'EQL-Midi-Probe.ps1'
    $script:WatchdogPath = Join-Path $script:RuntimeRoot 'EQL-GS-Synth-Watchdog.ps1'
}

function Invoke-ElevatedCopy {
    $arguments = New-Object Collections.Generic.List[string]
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add((Quote-ProcessArgument $PSCommandPath))
    if ($RecoverOnly) { $arguments.Add('-RecoverOnly') }
    if (-not [string]::IsNullOrWhiteSpace($LaunchPadPath)) {
        $arguments.Add('-LaunchPadPath')
        $arguments.Add((Quote-ProcessArgument $LaunchPadPath))
    }
    $arguments.Add('-LaunchTimeoutSeconds')
    $arguments.Add([string]$LaunchTimeoutSeconds)
    $arguments.Add('-InitializationTimeoutSeconds')
    $arguments.Add([string]$InitializationTimeoutSeconds)

    Write-Host 'Windows will ask for administrator approval. The workaround needs it only for one temporary 64-bit registry value.'
    try {
        $process = Start-Process -FilePath $script:PowerShellExe -Verb RunAs -Wait -PassThru -ArgumentList ($arguments -join ' ')
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
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporary = $Path + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $json, $utf8)
    if (Test-Path -LiteralPath $Path) {
        $replaceBackup = $Path + '.replace-backup-' + $PID
        if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) }
        [IO.File]::Replace($temporary, $Path, $replaceBackup)
        if (Test-Path -LiteralPath $replaceBackup) { [IO.File]::Delete($replaceBackup) }
    }
    else {
        [IO.File]::Move($temporary, $Path)
    }
}

function Get-RegistrySnapshot {
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($script:RegistrySubKey, $false)
        if ($null -eq $key) { throw 'The Windows Drivers32 registry key does not exist.' }
        $present = $key.GetValueNames() -contains $script:RegistryValueName
        if (-not $present) {
            return [ordered]@{ Present = $false; Value = $null; Kind = $null }
        }
        $value = $key.GetValue(
            $script:RegistryValueName,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        $kind = $key.GetValueKind($script:RegistryValueName).ToString()
        return [ordered]@{ Present = $true; Value = [string]$value; Kind = [string]$kind }
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
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
}

function Remove-GsSynthRegistration {
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($script:RegistrySubKey, $true)
        if ($null -eq $key) { throw 'Could not open Drivers32 for writing.' }
        $key.DeleteValue($script:RegistryValueName, $true)
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
    $actual = Get-RegistrySnapshot
    if ($actual.Present) { throw 'The GS Synth registration remained after the temporary delete.' }
}

function Restore-GsSynthRegistration {
    param([object]$State)
    Assert-WorkaroundState $State
    $current = Get-RegistrySnapshot
    if ($current.Present) {
        if (([string]$current.Value).Equals($script:ExpectedValue, [StringComparison]::OrdinalIgnoreCase) -and [string]$current.Kind -eq $script:ExpectedKind) {
            return
        }
        throw ('Refusing to overwrite a different current {0}\{1} value ({2}, {3}).' -f $script:RegistryDisplayPath, $script:RegistryValueName, $current.Value, $current.Kind)
    }

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($script:RegistrySubKey, $true)
        if ($null -eq $key) { throw 'Could not open Drivers32 for restoration.' }
        $key.SetValue(
            $script:RegistryValueName,
            $script:ExpectedValue,
            [Microsoft.Win32.RegistryValueKind]::String
        )
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }

    $verified = Get-RegistrySnapshot
    Assert-ExpectedBaseline $verified
}

function Invoke-MidiProbe {
    if (-not (Test-Path -LiteralPath $script:ProbePath -PathType Leaf)) {
        throw ('MIDI probe is missing: ' + $script:ProbePath)
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:PowerShellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Quote-ProcessArgument $script:ProbePath)
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
    if ($process.ExitCode -ne 0) {
        throw ('The fresh-process MIDI probe failed: ' + $stderr.Trim())
    }
    try {
        $result = $stdout | ConvertFrom-Json
        return @($result.devices)
    }
    catch {
        throw ('The MIDI probe returned invalid JSON: ' + $stdout.Trim())
    }
}

function Get-DeviceNames {
    param([object[]]$Devices)
    return @($Devices | ForEach-Object { [string]$_.name })
}

function Test-IsolationDelta {
    param([string[]]$Before, [string[]]$After)
    $remaining = New-Object Collections.Generic.List[string]
    foreach ($name in $Before) { $remaining.Add([string]$name) }
    $matches = @($remaining | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1) { return $false }
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        if ($remaining[$index].Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase)) {
            $remaining.RemoveAt($index)
            break
        }
    }
    $expected = @($remaining | Sort-Object)
    $actual = @($After | Sort-Object)
    return -not [bool](Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
}

function Test-RestoredDevices {
    param([string[]]$Before, [string[]]$After)
    $remaining = New-Object Collections.Generic.List[string]
    foreach ($name in $After) { $remaining.Add([string]$name) }
    foreach ($expected in $Before) {
        $found = -1
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            if ($remaining[$index].Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
                $found = $index
                break
            }
        }
        if ($found -lt 0) { return $false }
        $remaining.RemoveAt($found)
    }
    return [bool]($After | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
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

function Get-LaunchPadProcessRecords {
    $records = New-Object Collections.Generic.List[object]
    foreach ($process in Get-Process -Name LaunchPad -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = [string]$process.Path } catch { }
        $records.Add([pscustomobject]@{ Id = [int]$process.Id; Path = $path })
    }
    return @($records)
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
    return $records[0]
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
            return $records[0]
        }
        if ($records.Count -gt 0) {
            throw 'A LaunchPad process opened from a path other than the approved signed file.'
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'The approved signed LaunchPad did not open within 30 seconds.'
}

function Get-SavedLaunchPadPath {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { return $null }
    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        return Test-LaunchPadCandidate ([string]$config.LaunchPadPath)
    }
    catch { return $null }
}

function Save-LaunchPadPath {
    param([string]$Path)
    Write-JsonAtomic $script:ConfigPath ([ordered]@{
        Schema = 'eql-gs-synth-workaround-config-v1'
        LaunchPadPath = $Path
    })
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
    $candidate = Get-SavedLaunchPadPath
    if ($candidate) { return $candidate }
    $known = @(Get-KnownLaunchPadCandidates)
    if ($known.Count -eq 1) { return $known[0] }
    if ($known.Count -gt 1) {
        return @($known | Sort-Object { if ($_ -match 'EverQuest Legends') { 0 } else { 1 } }, Length)[0]
    }
    if ($AllowPrompt) { return Select-LaunchPadInteractively }
    return $null
}

function Get-CurrentRunLogSegment {
    param([string]$Path, [string]$BaselineText)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $current = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $current) { return '' }
    if ($BaselineText -and $current.StartsWith($BaselineText, [StringComparison]::Ordinal)) {
        return $current.Substring($BaselineText.Length)
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
    if (-not (Test-Path -LiteralPath $script:WatchdogPath -PathType Leaf)) {
        throw ('Restoration watchdog is missing: ' + $script:WatchdogPath)
    }
    $readyPath = Join-Path $Folder 'watchdog.ready.json'
    if (Test-Path -LiteralPath $readyPath) { [IO.File]::Delete($readyPath) }
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -StatePath {1} -ReadyPath {2}' -f `
        (Quote-ProcessArgument $script:WatchdogPath), `
        (Quote-ProcessArgument $StatePath), `
        (Quote-ProcessArgument $readyPath)
    $process = Start-Process -FilePath $script:PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Folder 'watchdog.stdout.log') `
        -RedirectStandardError (Join-Path $Folder 'watchdog.stderr.log')
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            throw ('Restoration watchdog exited before readiness with code ' + $process.ExitCode + '.')
        }
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            try {
                $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                $expectedStatePath = [IO.Path]::GetFullPath($StatePath)
                if ([string]$ready.Schema -eq 'eql-gs-synth-watchdog-ready-v1' -and
                    [int]$ready.WatchdogPid -eq [int]$process.Id -and
                    ([string]$ready.StatePath).Equals($expectedStatePath, [StringComparison]::OrdinalIgnoreCase)) {
                    return $process
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    try { $process.Kill() } catch { }
    throw 'Restoration watchdog did not acknowledge readiness within 10 seconds; no registry change was made.'
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
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'This workaround is only for 64-bit Windows.' }
    foreach ($required in @($script:ProbePath, $script:WatchdogPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw ('Required package file is missing: ' + $required) }
    }
    $helperHashes = Assert-HelperSourceIntegrity
    $launchPad = Resolve-LaunchPadPath $LaunchPadPath $false
    $launchPadDetails = $null
    if ($launchPad) { $launchPadDetails = Assert-OfficialLaunchPad $launchPad }
    $snapshot = Get-RegistrySnapshot
    Assert-ExpectedBaseline $snapshot
    $devices = @(Invoke-MidiProbe)
    $names = @(Get-DeviceNames $devices)
    $gsPresent = [bool]($names | Where-Object { $_.Equals($script:GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $gsPresent) { throw 'Microsoft GS Wavetable Synth is not freshly enumerable at baseline.' }
    $report = [ordered]@{
        Schema = 'eql-gs-synth-workaround-dry-run-v1'
        Version = $script:Version
        Mutated = $false
        IsAdministrator = Test-IsAdministrator
        LaunchPadPath = $launchPad
        LaunchPadFound = [bool]$launchPad
        LaunchPadSignatureValid = [bool]$launchPadDetails
        LaunchPadSigner = if ($launchPadDetails) { $launchPadDetails.SignerSubject } else { $null }
        HelperSha256 = $helperHashes
        RegistryPath = $script:RegistryDisplayPath
        RegistryValueName = $script:RegistryValueName
        RegistryValue = $snapshot.Value
        RegistryKind = $snapshot.Kind
        GsSynthPresent = $gsPresent
        MidiOutputs = $names
        EqgameRunning = [bool](Get-Process -Name eqgame -ErrorAction SilentlyContinue)
        LaunchPadRunning = [bool](Get-Process -Name LaunchPad -ErrorAction SilentlyContinue)
    }
    Write-Host ($report | ConvertTo-Json -Depth 6)
    if (-not $launchPad) {
        Write-Status 'Dry run passed for the fault-path checks, but LaunchPad.exe was not auto-detected. The live run will open a file picker.' 'WARN'
    }
    else {
        Write-Status 'Dry run passed. No registry, audio, game, service, or Wave Link state was changed.' 'PASS'
    }
}

function Invoke-SelfTest {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('eql-gs-selftest-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    Enter-WorkaroundMutex
    try {
        if (-not $script:OwnsInstanceMutex) { throw 'Single-instance mutex self-test failed.' }
        $validState = [pscustomobject]@{
            Schema = 'eql-gs-synth-workaround-state-v1'
            RegistryPath = $script:RegistryDisplayPath
            RegistryView = 'Registry64'
            ValueName = $script:RegistryValueName
            OriginalPresent = $true
            OriginalValue = $script:ExpectedValue
            OriginalKind = $script:ExpectedKind
        }
        Assert-WorkaroundState $validState
        $rejected = $false
        try {
            $invalid = $validState.PSObject.Copy()
            $invalid.RegistryPath = 'HKLM\SOFTWARE\NotApproved'
            Assert-WorkaroundState $invalid
        }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'State allow-list self-test failed.' }

        $before = @('USB MIDI', $script:GsSynthName, 'loopMIDI')
        $after = @('USB MIDI', 'loopMIDI')
        if (-not (Test-IsolationDelta $before $after)) { throw 'MIDI isolation delta self-test failed.' }
        if (Test-IsolationDelta $before @('USB MIDI')) { throw 'MIDI collateral-loss self-test failed.' }
        if (-not (Test-RestoredDevices $before $before)) { throw 'MIDI restoration self-test failed.' }
        if (Test-RestoredDevices @('Duplicate', 'Duplicate', $script:GsSynthName) @('Duplicate', $script:GsSynthName)) {
            throw 'MIDI duplicate-count restoration self-test failed.'
        }
        if ((Get-InitializationStatus 'Sound Manager loaded 5000 filenames') -ne 'SoundManager') { throw 'Sound marker self-test failed.' }
        if ((Get-InitializationStatus 'Sound Manager loaded; Fatal error occurred in mainthread') -ne 'Fatal') { throw 'Fatal precedence self-test failed.' }
        if ((Get-InitializationStatus 'Initializing character select UI.') -ne 'Ready') { throw 'Ready marker self-test failed.' }

        $jsonPath = Join-Path $temporaryRoot 'state.json'
        Write-JsonAtomic $jsonPath $validState
        Write-JsonAtomic $jsonPath $validState
        $roundTrip = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        Assert-WorkaroundState $roundTrip

        $dummyLaunchPad = Join-Path $temporaryRoot 'LaunchPad.exe'
        [IO.File]::WriteAllBytes($dummyLaunchPad, [byte[]](0))
        $resolved = Test-LaunchPadCandidate $dummyLaunchPad
        if ($resolved -ne [IO.Path]::GetFullPath($dummyLaunchPad)) { throw 'LaunchPad resolver self-test failed.' }
        $unsignedRejected = $false
        try { [void](Assert-OfficialLaunchPad $dummyLaunchPad) }
        catch { $unsignedRejected = $true }
        if (-not $unsignedRejected) { throw 'Unsigned LaunchPad rejection self-test failed.' }

        $protectedAcl = New-ProtectedDirectorySecurity
        $ownerSid = $protectedAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $rules = @($protectedAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
        if ($ownerSid -ne 'S-1-5-32-544' -or $rules.Count -ne 3 -or -not $protectedAcl.AreAccessRulesProtected) {
            throw 'Protected ProgramData ACL builder self-test failed.'
        }
        $helperHashes = Assert-HelperSourceIntegrity
        if ($helperHashes.Probe -ne $script:ExpectedProbeSha256 -or $helperHashes.Watchdog -ne $script:ExpectedWatchdogSha256) {
            throw 'Hash-pinned helper integrity self-test failed.'
        }

        $watchdogRegistryBefore = Get-RegistrySnapshot
        Assert-ExpectedBaseline $watchdogRegistryBefore
        $watchdogStatePath = Join-Path $temporaryRoot 'watchdog-state.json'
        $watchdogState = [ordered]@{
            Schema = 'eql-gs-synth-workaround-state-v1'
            Version = $script:Version
            Active = $true
            ParentPid = $PID
            ParentStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            DeadlineEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60
            RegistryPath = $script:RegistryDisplayPath
            RegistryView = 'Registry64'
            ValueName = $script:RegistryValueName
            OriginalPresent = $true
            OriginalValue = $script:ExpectedValue
            OriginalKind = $script:ExpectedKind
            WatchdogPid = 0
        }
        Write-JsonAtomic $watchdogStatePath $watchdogState
        $watchdogProcess = Start-RestorationWatchdog $watchdogStatePath $temporaryRoot
        $watchdogState.WatchdogPid = [int]$watchdogProcess.Id
        $watchdogState.Active = $false
        Write-JsonAtomic $watchdogStatePath $watchdogState
        if (-not $watchdogProcess.WaitForExit(15000)) {
            try { $watchdogProcess.Kill() } catch { }
            throw 'Watchdog lifecycle self-test timed out.'
        }
        $watchdogProcess.WaitForExit()
        $watchdogProcess.Refresh()
        $watchdogExitCode = [int]$watchdogProcess.ExitCode
        if ($watchdogExitCode -ne 0) { throw ('Watchdog lifecycle self-test exited ' + $watchdogExitCode + '.') }
        $watchdogReceipt = Get-Content -LiteralPath $watchdogStatePath -Raw | ConvertFrom-Json
        $watchdogReady = Get-Content -LiteralPath (Join-Path $temporaryRoot 'watchdog.ready.json') -Raw | ConvertFrom-Json
        if ([string]$watchdogReady.Schema -ne 'eql-gs-synth-watchdog-ready-v1' -or
            [int]$watchdogReady.WatchdogPid -ne [int]$watchdogProcess.Id -or
            -not [bool]$watchdogReceipt.WatchdogRestored -or
            [bool]$watchdogReceipt.Active) {
            throw 'Watchdog readiness/restoration receipt self-test failed.'
        }
        $watchdogRegistryAfter = Get-RegistrySnapshot
        if ($watchdogRegistryBefore.Present -ne $watchdogRegistryAfter.Present -or
            [string]$watchdogRegistryBefore.Value -ne [string]$watchdogRegistryAfter.Value -or
            [string]$watchdogRegistryBefore.Kind -ne [string]$watchdogRegistryAfter.Kind) {
            throw 'Watchdog self-test changed the restored registry baseline.'
        }

        Write-Status 'Self-test passed: state allow-list, collateral detection, log gates, atomic state, signed-launcher rejection, protected ACL construction, hash-pinned helpers, watchdog ready/restore lifecycle, path resolution, and single-instance guard.' 'PASS'
    }
    finally {
        Exit-WorkaroundMutex
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LiveWorkaround {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'This workaround is only for 64-bit Windows.' }
    if (-not (Test-IsAdministrator)) { throw 'The live workaround is not running as administrator.' }
    if (Get-Process -Name eqgame -ErrorAction SilentlyContinue) { throw 'eqgame.exe is already running. Close EQL before using this launcher.' }
    foreach ($required in @($script:ProbePath, $script:WatchdogPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw ('Required package file is missing: ' + $required) }
    }

    Initialize-ProtectedBackupRoot
    Stage-ProtectedRuntimeHelpers
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
    try {
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
        Write-Status 'The signed Daybreak LaunchPad is already open at normal user integrity. Click PLAY normally.'
        $eqgamePid = Wait-ForNewEqgame $baselinePids $LaunchTimeoutSeconds
        Write-Status ('Detected new eqgame.exe PID ' + $eqgamePid + '.')
        Wait-ForEqlInitialization $eqgamePid $debugLogPath $baselineLogText $InitializationTimeoutSeconds
        $outcome = 'success'
    }
    finally {
        $lastRestoreError = $null
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            try {
                Restore-GsSynthRegistration $state
                $restoredDevices = @(Invoke-MidiProbe)
                $restoredNames = @(Get-DeviceNames $restoredDevices)
                if (-not (Test-RestoredDevices $beforeNames $restoredNames)) {
                    throw ('Fresh-process restoration verification is incomplete. Baseline={0}; Restored={1}' -f ($beforeNames -join ', '), ($restoredNames -join ', '))
                }
                $state.Active = $false
                $state.Outcome = $outcome
                $state.ParentRestored = $true
                $state.RestoredAtUtc = [DateTime]::UtcNow.ToString('o')
                $state.RestoredMidiOutputs = $restoredNames
                Write-JsonAtomic $statePath $state
                $restored = $true
                Write-Status 'Exact 64-bit midi=wdmaud.drv registration restored; GS Synth is freshly enumerable again.' 'PASS'
                break
            }
            catch {
                $lastRestoreError = $_.Exception
                Start-Sleep -Seconds 1
            }
        }
        if (-not $restored) {
            Write-Status ('CRITICAL RESTORE ERROR: ' + $lastRestoreError.Message) 'ERROR'
            Write-Status ('Leave this window open briefly; watchdog PID {0} will retry restoration when the parent exits or its deadline expires.' -f $state.WatchdogPid) 'ERROR'
            throw ('The parent could not verify GS Synth restoration: ' + $lastRestoreError.Message)
        }
    }

    if ($outcome -eq 'success') {
        Write-Status 'EQL passed the guarded initialization boundary and all Windows MIDI state was restored.' 'PASS'
    }
}

$exitCode = 0
try {
    if ($SelfTest) {
        Invoke-SelfTest
    }
    elseif ($DryRun) {
        Invoke-DryRun
    }
    elseif (-not (Test-IsAdministrator)) {
        if (-not $RecoverOnly) {
            if (Get-Process -Name eqgame -ErrorAction SilentlyContinue) {
                throw 'eqgame.exe is already running. Close EQL before using this launcher.'
            }
            $approvedPath = Resolve-LaunchPadPath $LaunchPadPath $true
            if (-not $approvedPath) { throw 'The official EverQuest Legends LaunchPad.exe was not selected.' }
            $approvedDetails = Assert-OfficialLaunchPad $approvedPath
            Save-LaunchPadPath $approvedPath
            $normalLaunchPad = Start-OrUseOfficialLaunchPad $approvedPath
            Write-Status ('Verified signed Daybreak LaunchPad and opened it before UAC at normal user integrity (PID {0}).' -f $normalLaunchPad.Id) 'PASS'
            $LaunchPadPath = $approvedPath
        }
        $exitCode = Invoke-ElevatedCopy
    }
    elseif ($RecoverOnly) {
        Enter-WorkaroundMutex
        try {
            Initialize-ProtectedBackupRoot
            Stage-ProtectedRuntimeHelpers
            [void](Invoke-StaleRecovery)
        }
        finally { Exit-WorkaroundMutex }
    }
    else {
        Enter-WorkaroundMutex
        try { Invoke-LiveWorkaround }
        finally { Exit-WorkaroundMutex }
    }
}
catch {
    Write-Status $_.Exception.Message 'ERROR'
    $exitCode = 1
}
exit $exitCode
