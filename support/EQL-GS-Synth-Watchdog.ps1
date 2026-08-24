[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [Parameter(Mandatory = $true)]
    [string]$ReadyPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RegistrySubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$RegistryDisplayPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$RegistryValueName = 'midi'
$ExpectedValue = 'wdmaud.drv'
$ExpectedKind = 'String'
$GsSynthName = 'Microsoft GS Wavetable Synth'
$ProbePath = Join-Path $PSScriptRoot 'EQL-Midi-Probe.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.watchdog.tmp'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), $utf8)
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

function Assert-State {
    param([object]$State)
    if ([string]$State.Schema -ne 'eql-gs-synth-workaround-state-v1') { throw 'State schema is not recognized.' }
    if ([string]$State.RegistryPath -ne $RegistryDisplayPath) { throw 'State registry path is not approved.' }
    if ([string]$State.RegistryView -ne 'Registry64') { throw 'State registry view is not approved.' }
    if ([string]$State.ValueName -ne $RegistryValueName) { throw 'State value name is not approved.' }
    if (-not [bool]$State.OriginalPresent) { throw 'State does not contain the required original value.' }
    if (-not ([string]$State.OriginalValue).Equals($ExpectedValue, [StringComparison]::OrdinalIgnoreCase)) { throw 'State original value is not approved.' }
    if ([string]$State.OriginalKind -ne $ExpectedKind) { throw 'State original type is not approved.' }
    if ([int]$State.ParentPid -le 0) { throw 'State parent PID is invalid.' }
    $parentStart = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$State.ParentStartTimeUtc, [ref]$parentStart)) { throw 'State parent start time is invalid.' }
    if ([int64]$State.DeadlineEpoch -le 0) { throw 'State deadline is invalid.' }
}

function Get-RegistrySnapshot {
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($RegistrySubKey, $false)
        if ($null -eq $key) { throw 'Drivers32 does not exist.' }
        $present = $key.GetValueNames() -contains $RegistryValueName
        if (-not $present) { return [ordered]@{ Present = $false; Value = $null; Kind = $null } }
        return [ordered]@{
            Present = $true
            Value = [string]$key.GetValue($RegistryValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind($RegistryValueName).ToString()
        }
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Restore-Registration {
    param([object]$State)
    Assert-State $State
    $current = Get-RegistrySnapshot
    if ($current.Present) {
        if (([string]$current.Value).Equals($ExpectedValue, [StringComparison]::OrdinalIgnoreCase) -and [string]$current.Kind -eq $ExpectedKind) { return }
        throw ('Refusing to overwrite a different current Drivers32 midi value: {0} ({1}).' -f $current.Value, $current.Kind)
    }
    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($RegistrySubKey, $true)
        if ($null -eq $key) { throw 'Could not open Drivers32 for restoration.' }
        $key.SetValue($RegistryValueName, $ExpectedValue, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        if ($key) { $key.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
    $verified = Get-RegistrySnapshot
    if (-not $verified.Present -or -not ([string]$verified.Value).Equals($ExpectedValue, [StringComparison]::OrdinalIgnoreCase) -or [string]$verified.Kind -ne $ExpectedKind) {
        throw 'Exact Drivers32 midi restoration verification failed.'
    }
}

function Test-GsSynthFreshProcess {
    if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) { throw 'MIDI probe is missing.' }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShellExe
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Quote-ProcessArgument $ProbePath)
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
        throw 'Fresh-process MIDI probe timed out.'
    }
    if ($process.ExitCode -ne 0) { throw ('Fresh-process MIDI probe failed: ' + $stderr.Trim()) }
    $result = $stdout | ConvertFrom-Json
    return [bool](@($result.devices) | Where-Object { ([string]$_.name).Equals($GsSynthName, [StringComparison]::OrdinalIgnoreCase) })
}

$cachedState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
Assert-State $cachedState
$stateDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $StatePath)).TrimEnd('\')
$readyDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $ReadyPath)).TrimEnd('\')
if (-not $stateDirectory.Equals($readyDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Watchdog ready file must be in the same transaction directory as state.json.'
}
Write-JsonAtomic $ReadyPath ([ordered]@{
    Schema = 'eql-gs-synth-watchdog-ready-v1'
    WatchdogPid = $PID
    StatePath = [IO.Path]::GetFullPath($StatePath)
    ReadyAtUtc = [DateTime]::UtcNow.ToString('o')
})

while ($true) {
    $parentAlive = $false
    $parent = Get-Process -Id ([int]$cachedState.ParentPid) -ErrorAction SilentlyContinue
    if ($parent) {
        try {
            $observedStart = $parent.StartTime.ToUniversalTime().ToString('o')
            $parentAlive = $observedStart -eq [string]$cachedState.ParentStartTimeUtc
        }
        catch { $parentAlive = $false }
    }
    $expired = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [int64]$cachedState.DeadlineEpoch
    $markedInactive = $false
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $currentState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            Assert-State $currentState
            $markedInactive = -not [bool]$currentState.Active
            $cachedState = $currentState
        }
        catch { }
    }
    if ($markedInactive -or -not $parentAlive -or $expired) { break }
    Start-Sleep -Seconds 1
}

$lastError = $null
for ($attempt = 1; $attempt -le 60; $attempt++) {
    try {
        Restore-Registration $cachedState
        if (-not (Test-GsSynthFreshProcess)) { throw 'GS Synth did not freshly enumerate after watchdog restoration.' }
        $cachedState.Active = $false
        $cachedState | Add-Member -NotePropertyName WatchdogRestored -NotePropertyValue $true -Force
        $cachedState | Add-Member -NotePropertyName WatchdogRestoredAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-JsonAtomic $StatePath $cachedState
        Write-Output 'PASS: watchdog verified exact GS Synth restoration.'
        exit 0
    }
    catch {
        $lastError = $_.Exception
        Start-Sleep -Seconds 1
    }
}
throw ('Watchdog could not verify GS Synth restoration: ' + $lastError.Message)
