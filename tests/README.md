# Maintainer verification (no live launch)

Run on 64-bit Windows using the built-in **Windows PowerShell 5.1**, at normal user privilege.

## Isolated regressions

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Safety.ps1
```

The suite AST-parses the exact production file and extracts its functions. It never executes the production mode dispatcher. Registry, UAC, and game-start boundaries are forbidden; recovery/watchdog scenarios use mock registry/device/process observations and real JSON receipts in a unique owned temporary directory. Probe regressions start only disposable fixture PowerShell children (including a hung child and full stderr pipe). They do not enumerate real MIDI devices.

`-SourcePath <path>` tests a clean extraction. `-SkipPipeStress` is only for reproducing the original blocking implementation without hanging; it is not an acceptance run.

## Local candidate build and read-only machine checks

**Do not run the builder over the accepted artifact directory.** Run it only in a disposable checkout. The released RC8 ZIP is frozen with its pre-test documentation; the current repository guides differ, so a rebuild is a new, unaccepted package, not a reproduction or replacement of the published ZIP.

Python 3, standard library only:

```powershell
python .\tests\verify_candidate.py
```

This builds a **new local RC8 candidate** under `release/audit-rc8/` (overwriting outputs there), runs the regression suite against source and extracted bytes, exercises the actual wrapper's `--check-only`, runs a fresh real 64-bit MIDI enumeration, and checks wrong-hash/direct-entry refusals. It records before/after registry value/type, relevant processes/services, and protected transaction-state hashes. It does not elevate, launch EQL, stop anything, or mutate registry/audio state.

Generated logs include local paths and device names: review before sharing. `verification.json` records each gate. A failing gate is not waived by an otherwise valid ZIP. A concurrent user-driven application change can make the before/after check inconclusive; investigate rather than relabeling it PASS.

The ZIP contains only the player files and checksums; tests are repository-only. Source changes require rebuilding and rerunning all gates. Do not publish or install the candidate based on these tests alone: an approved exact-package UAC/launch/isolation/restoration test and audible-output confirmation remain separate acceptance requirements. No network publication or Git commit is performed by these tools.
