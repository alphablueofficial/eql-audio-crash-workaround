[CmdletBinding()]
param(
    [string]$SourcePath = '',
    [switch]$SkipPipeStress
)

# Dependency-free Windows PowerShell 5.1 regressions. Never execute script entry modes.
# Production functions are AST-extracted; registry writes, UAC, and game startup are forbidden.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $SourcePath) { $SourcePath = Join-Path $PSScriptRoot '..\EQL-Audio-Fix.ps1' }
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $SourcePath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($node.Extent.Text))
}
$script:RegistryDisplayPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32'
$script:RegistryValueName = 'midi'
$script:ExpectedValue = 'wdmaud.drv'
$script:ExpectedKind = 'String'
$script:GsSynthName = 'Microsoft GS Wavetable Synth'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:RuntimeSha256 = 'a' * 64
$script:LogFile = $null
$script:passed = 0; $script:failed = 0; $script:skipped = 0
$script:root = Join-Path ([IO.Path]::GetTempPath()) ('eql-safety-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:root)
function Invoke-WithDrivers32 { throw 'FORBIDDEN: real registry access from regression suite.' }
function Invoke-ElevatedCopy { throw 'FORBIDDEN: UAC from regression suite.' }
function Start-OrUseOfficialLaunchPad { throw 'FORBIDDEN: game startup from regression suite.' }
function Assert-True { param([bool]$Value, [string]$Reason) if (-not $Value) { throw $Reason } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $caught -notmatch $Pattern) { throw ('Expected error /{0}/; got: {1}' -f $Pattern, $caught) }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    if ($SkipPipeStress -and $Name -eq 'fresh probe drains stderr without pipe deadlock') {
        $script:skipped++; Write-Host ('SKIP ' + $Name); return
    }
    try { & $Action; $script:passed++; Write-Host ('PASS ' + $Name) }
    catch { $script:failed++; Write-Host ('FAIL {0}: {1}' -f $Name, $_.Exception.Message) }
}
function New-TestState {
    [pscustomobject]@{
        Schema = 'eql-gs-synth-workaround-state-v1'; Active = $true
        RegistryPath = $script:RegistryDisplayPath; RegistryView = 'Registry64'; ValueName = 'midi'
        OriginalPresent = $true; OriginalValue = 'wdmaud.drv'; OriginalKind = 'String'
        ParentPid = $PID; ParentStartTimeUtc = [DateTime]::UtcNow.ToString('o')
        DeadlineEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 120
        BaselineMidiOutputs = @('Microsoft GS Wavetable Synth', 'Controller', 'Controller')
    }
}
function New-TransactionFixture {
    $folder = Join-Path $script:root ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $statePath = Join-Path $folder 'state.json'
    Write-JsonAtomic $statePath (New-TestState)
    return $statePath
}
function New-ProbeFixture {
    param([string]$Body)
    $path = Join-Path $script:root ([Guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($path, "param(`$Mode, `$ExpectedScriptSha256)`r`n" + $Body)
    return $path
}
function Test-PreIsolationBaselineCapture {
    param([object]$Body)
    $assignments = @($Body.FindAll({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -ceq 'baselinePids'
    }, $false))
    $removals = @($Body.FindAll({ param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Remove-GsSynthRegistration'
    }, $false))
    return $assignments.Count -eq 1 -and $removals.Count -eq 1 -and
        $assignments[0].Extent.StartOffset -lt $removals[0].Extent.StartOffset
}
try {
    Test-Case 'PowerShell 5.1 source parses' { Assert-True ($PSVersionTable.PSVersion.Major -eq 5) 'Run with built-in Windows PowerShell 5.1.' }
    Test-Case 'multiset permits reordered case variants' {
        Assert-True (Test-DeviceNameMultisetEqual @('A','b','A') @('a','A','B')) 'Equivalent multiset rejected.'
    }
    Test-Case 'multiset rejects duplicate replacement' {
        Assert-True (-not (Test-DeviceNameMultisetEqual @('A','A','b') @('a','b','b'))) 'Duplicate mismatch accepted.'
    }
    Test-Case 'multiset rejects unexpected extra' {
        Assert-True (-not (Test-DeviceNameMultisetEqual @('A') @('A','B'))) 'Extra output accepted.'
    }
    Test-Case 'isolation removes only one GS synth' {
        Assert-True (Test-IsolationDelta @($script:GsSynthName,'A','A') @('a','A')) 'Valid delta rejected.'
        Assert-True (-not (Test-IsolationDelta @($script:GsSynthName,'A','A') @('A'))) 'Lost non-GS device accepted.'
        Assert-True (-not (Test-IsolationDelta @($script:GsSynthName,$script:GsSynthName) @())) 'Duplicate GS baseline accepted.'
    }
    Test-Case 'log append and rollover remain supported' {
        $path = Join-Path $script:root 'dbg.txt'
        foreach ($case in @(@('old','oldnew','new'), @('old-long','new','new'), @('old','old',''), @('old','different','different'), @('old','',''))) {
            [IO.File]::WriteAllText($path, $case[1])
            Assert-True ((Get-CurrentRunLogSegment $path $case[0]) -ceq $case[2]) 'Wrong current-run log segment.'
        }
    }
    Test-Case 'fatal overrides ready marker' {
        Assert-True ((Get-InitializationStatus 'Starting char select. Fatal error occurred in mainthread') -eq 'Fatal') 'Fatal lost to success.'
    }
    Test-Case 'fresh probe accepts valid empty device list' {
        $script:RuntimePath = New-ProbeFixture 'Write-Output ''{"schema":"eql-midi-probe-v1","processBitness":64,"devices":[]}'''
        Assert-True (@(Invoke-MidiProbe).Count -eq 0) 'Empty device list rejected.'
    }
    Test-Case 'fresh probe enforces wall-clock timeout' {
        $script:RuntimePath = New-ProbeFixture 'Start-Sleep -Seconds 5'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Invoke-MidiProbe -TimeoutMilliseconds 300 } 'timed out'
        Assert-True ($timer.Elapsed.TotalSeconds -lt 3) ('Probe exceeded bounded timeout: ' + $timer.Elapsed.TotalSeconds)
    }
    Test-Case 'fresh probe drains stderr without pipe deadlock' {

        $script:RuntimePath = New-ProbeFixture "[Console]::Error.Write(('x' * 100000)); [Console]::Out.Write('{`"schema`":`"eql-midi-probe-v1`",`"processBitness`":64,`"devices`":[]}')"
        # The old implementation needs -SkipPipeStress for a bounded RED run.
        Assert-True (@(Invoke-MidiProbe).Count -eq 0) 'Valid child with stderr output failed.'
    }
    Test-Case 'fresh probe rejects wrong schema' {
        $script:RuntimePath = New-ProbeFixture "Write-Output '{`"schema`":`"wrong`",`"processBitness`":64,`"devices`":[]}'"
        Assert-Throws { Invoke-MidiProbe } 'invalid output'
    }
    Test-Case 'fresh probe rejects device enumeration errors' {
        $script:RuntimePath = New-ProbeFixture "Write-Output '{`"schema`":`"eql-midi-probe-v1`",`"processBitness`":64,`"devices`": [{`"id`":0,`"name`":`"Microsoft GS Wavetable Synth`",`"result`":5}]}'"
        Assert-Throws { Invoke-MidiProbe } 'invalid output'
    }
    Test-Case 'failed recovery stays active for retry' {
        $statePath = New-TransactionFixture
        $script:BackupRoot = Split-Path $statePath -Parent
        function Get-RegistrySnapshot { return @{ Present=$true; Value='wdmaud.drv'; Kind='String' } }
        function Invoke-MidiProbe { throw 'fixture probe failed' }
        Assert-Throws { Invoke-StaleRecovery } 'fixture probe failed'
        $readback = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Assert-True ($readback.Active -eq $true) 'Recovery cleared Active before verification.'
        Assert-True (-not $readback.PSObject.Properties['RecoveredByNextRun']) 'Recovery falsely wrote completed receipt.'
    }
    Test-Case 'recovery rejects missing non-GS MIDI output' {
        $statePath = New-TransactionFixture
        $script:BackupRoot = Split-Path $statePath -Parent
        function Get-RegistrySnapshot { return @{ Present=$true; Value='wdmaud.drv'; Kind='String' } }
        function Invoke-MidiProbe { return @([pscustomobject]@{name=$script:GsSynthName}, [pscustomobject]@{name='Controller'}) }
        Assert-Throws { Invoke-StaleRecovery } 'baseline|restoration'
        Assert-True ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).Active -eq $true) 'Incomplete recovery marked inactive.'
    }
    Test-Case 'recovery completes exact duplicate-aware baseline' {
        $statePath = New-TransactionFixture
        $script:BackupRoot = Split-Path $statePath -Parent
        function Get-RegistrySnapshot { return @{ Present=$true; Value='wdmaud.drv'; Kind='String' } }
        function Invoke-MidiProbe { return @('controller',$script:GsSynthName,'Controller') | ForEach-Object { [pscustomobject]@{name=$_} } }
        Assert-True ((Invoke-StaleRecovery) -eq 1) 'Recovery count wrong.'
        $readback = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Assert-True (-not $readback.Active -and $readback.RecoveredByNextRun) 'Successful recovery receipt missing.'
    }
    Test-Case 'watchdog rejects missing non-GS MIDI output' {
        $StatePath = New-TransactionFixture
        $ReadyPath = Join-Path (Split-Path $StatePath -Parent) 'watchdog.ready.json'
        function Get-Process { return $null }
        function Start-Sleep { }
        function Get-RegistrySnapshot { return @{ Present=$true; Value='wdmaud.drv'; Kind='String' } }
        function Invoke-MidiProbe { return @([pscustomobject]@{name=$script:GsSynthName}) }
        Assert-Throws { Invoke-Watchdog } 'baseline|restoration'
        Assert-True ((Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).Active -eq $true) 'Watchdog falsely completed partial recovery.'
    }
    Test-Case 'watchdog verifies exact baseline and writes receipt' {
        $StatePath = New-TransactionFixture
        $ReadyPath = Join-Path (Split-Path $StatePath -Parent) 'watchdog.ready.json'
        function Get-Process { return $null }
        function Start-Sleep { }
        function Get-RegistrySnapshot { return @{ Present=$true; Value='wdmaud.drv'; Kind='String' } }
        function Invoke-MidiProbe { return @('Controller','Controller',$script:GsSynthName) | ForEach-Object { [pscustomobject]@{name=$_} } }
        Invoke-Watchdog | Out-Null
        $readback = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Assert-True (-not $readback.Active -and $readback.WatchdogRestored) 'Watchdog receipt missing.'
    }
    Test-Case 'recovery refuses malformed receipts instead of claiming success' {
        $statePath = New-TransactionFixture
        $script:BackupRoot = Split-Path $statePath -Parent
        [IO.File]::WriteAllText($statePath, '{broken')
        Assert-Throws { Invoke-StaleRecovery } 'invalid state'
    }
    Test-Case 'state-v1 without runtime hash remains supported' {
        $state = New-TestState
        Assert-WorkaroundState $state
        $state.Active = 'false'
        Assert-Throws { Assert-WorkaroundState $state } 'Boolean'
    }
    Test-Case 'state rejects missing or malformed baseline' {
        foreach ($bad in @($null, 'Microsoft GS Wavetable Synth', @('Other'), @($script:GsSynthName, 42))) {
            $state = New-TestState
            $state.BaselineMidiOutputs = $bad
            Assert-Throws { Assert-WorkaroundState $state } 'baseline'
        }
    }
    Test-Case 'game waiter binds the selected installation and start time' {
        function Get-Process { [pscustomobject]@{Id=101; Path='C:\Approved-EQL\eqgame.exe'; StartTime=[DateTime]'2026-01-01T12:00:00Z'} }
        function Write-Status { }
        $game = Wait-ForNewEqgame -BaselinePids @() -TimeoutSeconds 1 -ExpectedPath 'C:\Approved-EQL\eqgame.exe'
        Assert-True ($game.Id -eq 101 -and $game.Path -eq 'C:\Approved-EQL\eqgame.exe' -and $game.StartTimeUtc) 'Game identity not captured.'
    }
    Test-Case 'game waiter rejects wrong or ambiguous installations' {
        function Get-Process { [pscustomobject]@{Id=202; Path='D:\Other-EQ\eqgame.exe'; StartTime=[DateTime]::UtcNow} }
        function Write-Status { }
        Assert-Throws { Wait-ForNewEqgame -BaselinePids @() -TimeoutSeconds 1 -ExpectedPath 'C:\Approved-EQL\eqgame.exe' } 'path|installation'
        function Get-Process { @([pscustomobject]@{Id=101; Path='C:\Approved-EQL\eqgame.exe'}, [pscustomobject]@{Id=202; Path='D:\Other-EQ\eqgame.exe'}) }
        Assert-Throws { Wait-ForNewEqgame -BaselinePids @() -TimeoutSeconds 1 -ExpectedPath 'C:\Approved-EQL\eqgame.exe' } 'multiple|exactly one'
    }
    Test-Case 'initialization refuses reused PID before reading ready log' {
        $game = [pscustomobject]@{Id=101; Path='C:\Approved-EQL\eqgame.exe'; StartTimeUtc=([DateTime]'2026-01-01T12:00:00Z').ToUniversalTime().ToString('o')}
        function Get-Process { [pscustomobject]@{Id=101; Path='C:\Approved-EQL\eqgame.exe'; StartTime=[DateTime]'2026-01-01T12:01:00Z'} }
        function Get-CurrentRunLogSegment { throw 'UNEXPECTED_LOG_READ' }
        Assert-Throws { Wait-ForEqlInitialization -Game $game -DebugLogPath 'fixture' -BaselineLogText '' -TimeoutSeconds 1 } 'identity|replaced'
    }
    Test-Case 'PLAY baseline is captured before isolation, not after' {
        $live = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-LiveWorkaround' }, $false)[0]
        Assert-True (Test-PreIsolationBaselineCapture $live.Body) 'Baseline must be assigned exactly once before the sole isolation call.'
    }
    Test-Case 'PLAY ordering guard rejects absent, duplicate and late assignments' {
        foreach ($text in @('Remove-GsSynthRegistration', '$baselinePids=@(); $baselinePids=@(); Remove-GsSynthRegistration', 'Remove-GsSynthRegistration; $baselinePids=@()', '$baselinePids=@()')) {
            Assert-True (-not (Test-PreIsolationBaselineCapture ([ScriptBlock]::Create($text).Ast))) 'Malformed baseline ordering incorrectly passed.'
        }
        Assert-True (Test-PreIsolationBaselineCapture ([ScriptBlock]::Create('$baselinePids=@(); Remove-GsSynthRegistration').Ast)) 'Valid baseline ordering rejected.'
    }
}
finally {
    # This run owns only its generated temporary tree.
    Remove-Item -LiteralPath $script:root -Recurse -Force
}
Write-Host ('RESULT: {0} passed; {1} failed.' -f $script:passed, $script:failed)
if ($script:skipped) { Write-Host ('INCOMPLETE: {0} skipped.' -f $script:skipped) }
if ($script:failed -or $script:skipped) { exit 1 }
exit 0
