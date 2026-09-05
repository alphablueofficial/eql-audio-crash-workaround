"""Build and verify a LOCAL candidate without UAC, launch, or registry writes.

Python 3 stdlib + built-in Windows PowerShell 5.1 only. Run at medium integrity.
Writes only release/ output and owned temporary files. This is NOT live acceptance.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PS = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
FLAGS = subprocess.CREATE_NO_WINDOW
OUTPUT = ROOT / 'release' / 'audit-rc8'
FILES = ('EQL-Audio-Fix.ps1', 'Launch EQL Audio Fix.cmd',
         'Emergency Restore Windows MIDI.cmd', 'README.md', 'TECHNICAL.md',
         'SECURITY.md', 'LICENSE')
RESULTS: list[dict] = []


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(args, *, cwd=ROOT, timeout=90, shell=False):
    return subprocess.run(args, cwd=cwd, shell=shell, input='', text=True,
                          encoding='utf-8', errors='replace', capture_output=True,
                          timeout=timeout, creationflags=FLAGS)


def powershell(*args):
    return run([str(PS), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', *args])


def record(name, passed, **details):
    RESULTS.append(dict(name=name, passed=bool(passed), **details))
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)
    (OUTPUT / 'verification.json').write_text(json.dumps(RESULTS, indent=2), encoding='utf-8')


def snapshot():
    # Read-only system observation; do not print command lines or registry exports.
    command = r'''
$ErrorActionPreference='Stop'
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
$key=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32',$false)
try {
 $reg = if($key.GetValueNames() -contains 'midi') {
  @{Present=$true;Value=$key.GetValue('midi',$null,'DoNotExpandEnvironmentNames');Kind=$key.GetValueKind('midi').ToString()}
 } else {@{Present=$false;Value=$null;Kind=$null}}
} finally {$key.Dispose();$base.Dispose()}
$processes=@(Get-Process | Where-Object {$_.ProcessName -match '^(eqgame|LaunchPad|WaveLink.*|obs64|rekordbox|Streamer.bot)$'} | Sort-Object Id | ForEach-Object {
 @{Name=$_.ProcessName;Id=$_.Id;Started=$(if($null -ne $_.StartTime){$_.StartTime.ToUniversalTime().ToString('o')}else{'unavailable'})}
})
$services=@(Get-Service | Where-Object {$_.Name -match 'Wave|Audio' -or $_.DisplayName -match 'Wave Link'} | Sort-Object Name | ForEach-Object {@{Name=$_.Name;Status=$_.Status.ToString()}})
$root=Join-Path $env:ProgramData 'EQL-GS-Synth-Workaround'
$receipts=@(if(Test-Path -LiteralPath $root){Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {$_.Name -eq 'state.json'} | Sort-Object FullName | ForEach-Object {@{Path=$_.FullName;Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}}})
@{Registry=$reg;Processes=$processes;Services=$services;ProtectedRootExists=(Test-Path -LiteralPath $root);Receipts=$receipts} | ConvertTo-Json -Depth 8 -Compress
'''
    result = powershell('-Command', command)
    if result.returncode:
        raise RuntimeError('Read-only snapshot failed: ' + result.stderr)
    return json.loads(result.stdout)


def verify(folder: Path, label: str):
    script = folder / FILES[0]
    digest = sha(script.read_bytes())
    result = powershell('-File', str(ROOT / 'tests/Test-Safety.ps1'), '-SourcePath', str(script))
    (OUTPUT / f'{label}-tests.txt').write_text(result.stdout + result.stderr, encoding='utf-8')
    summary = re.search(r'RESULT: (\d+) passed; (\d+) failed\.', result.stdout)
    record(label + ' regression suite', result.returncode == 0 and summary and summary[2] == '0',
           summary=summary[0] if summary else None, exit_code=result.returncode)
    # Fixed shell command, never interpolate operator/source text into CMD syntax.
    result = run('"Launch EQL Audio Fix.cmd" --check-only', cwd=folder, shell=True)
    (OUTPUT / f'{label}-check.txt').write_text(result.stdout + result.stderr, encoding='utf-8')
    record(label + ' exact wrapper check-only', result.returncode == 0 and '"Mutated":  false' in result.stdout,
           exit_code=result.returncode)
    result = powershell('-File', str(script), '-Mode', 'Probe', '-ExpectedScriptSha256', digest)
    try:
        probe = json.loads(result.stdout)
    except ValueError:
        probe = {}
    record(label + ' real 64-bit MIDI probe', result.returncode == 0 and probe.get('processBitness') == 64
           and probe.get('schema') == 'eql-midi-probe-v1'
           and all(d.get('result') == 0 for d in probe.get('devices', [])), probe=probe)
    result = powershell('-File', str(script), '-Mode', 'Probe', '-ExpectedScriptSha256', '0' * 64)
    record(label + ' wrong-hash refusal', result.returncode != 0 and 'SHA-256 mismatch' in result.stderr)
    for mode in ('Launch', 'Check', 'Recover'):
        result = powershell('-File', str(script), '-Mode', mode)
        record(label + ' direct ' + mode + ' refusal', result.returncode != 0 and
               ('must start through' in result.stdout or 'requires the hash-verifying' in result.stdout))


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    before = snapshot()
    (OUTPUT / 'before.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
    try:
        verify(ROOT, 'source')
        package = 'EQL-Audio-Crash-Workaround-v1.0.0-rc8'
        data = {name: (ROOT / name).read_bytes() for name in FILES}
        manifest = ''.join(f'{sha(value)}  {name}\n' for name, value in data.items())
        data['CHECKSUMS-SHA256.txt'] = manifest.encode('utf-8')
        archive = OUTPUT / (package + '.zip')
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
            for name, value in data.items():
                # Fixed metadata makes rebuilding unchanged candidate bytes reproducible.
                info = zipfile.ZipInfo(package + '/' + name, (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                z.writestr(info, value)
        archive.with_suffix('.zip.sha256.txt').write_text(f'{sha(archive.read_bytes())}  {archive.name}\n', encoding='ascii')
        with tempfile.TemporaryDirectory(prefix='eql-candidate-') as temp, zipfile.ZipFile(archive) as z:
            assert len(z.namelist()) == len(data) == len(set(z.namelist()))
            for entry in z.infolist():
                path = PurePosixPath(entry.filename)
                assert not path.is_absolute() and '..' not in path.parts and '\\' not in entry.filename
                assert len(path.parts) == 2 and path.parts[0] == package and path.name in data
                assert z.read(entry) == data[path.name]
            z.extractall(temp)
            extracted = Path(temp) / package
            for line in (extracted / 'CHECKSUMS-SHA256.txt').read_text().splitlines():
                digest, name = line.split('  ', 1)
                assert sha((extracted / name).read_bytes()) == digest
            record('safe ZIP paths, exact source bytes and internal checksums', True,
                   zip_sha256=sha(archive.read_bytes()), script_sha256=sha(data[FILES[0]]), files=len(data))
            verify(extracted, 'extracted')
    finally:
        after = snapshot()
        (OUTPUT / 'after.json').write_text(json.dumps(after, indent=2), encoding='utf-8')
        record('observed registry/process/service/receipt state unchanged', before == after)
    failures = [r['name'] for r in RESULTS if not r['passed']]
    print(json.dumps(dict(gates=len(RESULTS), failed=failures, live_acceptance=False, output=str(OUTPUT))))
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
