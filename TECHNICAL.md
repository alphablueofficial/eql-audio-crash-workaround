# Technical design, safety, and evidence

This document describes the trust boundaries, transaction sequence, supported configurations, recovery model, and evidence behind the player workflow in [`README.md`](README.md).

## Scope

The workaround targets one observed EQL launch signature:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

A strong confirmation canary is that `Sound=0` avoids the crash while removing game audio. Other `#630` sequences, authentication/server failures, LaunchPad patching, ordinary gameplay crashes, and private-instance failures are outside scope.

## Portable but fail-closed

| Setup | Behavior |
|---|---|
| EQL on another fixed drive | Searches common EQL locations on all fixed drives |
| Custom EQL location | Uses an EQL desktop shortcut when available or opens a file picker |
| Multiple installations | Requires the player to select one rather than guessing |
| No Wave Link | Works without it; Wave Link is not a dependency |
| VoiceMeeter, Sonar, VB-Cable, OBS, or other virtual audio | Leaves it unchanged |
| Additional physical or virtual MIDI outputs | Allows them, but requires an exact duplicate-aware before/after match except for temporary GS Synth removal |
| Different `Drivers32\midi` baseline | Stops without changing it |
| Changed Daybreak launcher identity | Stops until the project is reviewed and updated |

The tool is portable across ordinary install paths and audio setups, not universal across unknown Windows MIDI states.

## Exact system boundary

The only temporary system mutation is deletion and restoration of:

```text
Registry view: 64-bit
Path: HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32
Value: midi
Data: wdmaud.drv
Type: REG_SZ
```

The workaround does not modify game files, inject code, alter playback/recording defaults, stop services, replace a driver, install persistence, contact a network service, or read credentials.

## Transaction sequence

During a live RC7 launch:

1. `Launch EQL Audio Fix.cmd` invokes the built-in 64-bit Windows PowerShell path.
2. The wrapper reads the script's exact bytes once, computes SHA-256, and executes those bytes from memory.
3. At normal privilege, the script checks the supported registry/MIDI baseline, validates the selected `LaunchPad.exe`, and opens that signed launcher at medium integrity.
4. The UAC bootstrap re-reads the source and requires it to match the immutable entry digest before parsing elevated code.
5. The elevated phase creates or validates administrator-owned, non-reparse ProgramData storage and stages the exact trusted runtime bytes there.
6. Any valid prior active transaction is recovered before a new launch begins.
7. The running LaunchPad path, signature, product metadata, and integrity are revalidated.
8. The script requires exactly one freshly enumerable Microsoft GS Wavetable Synth output.
9. It creates a unique transaction folder, exports the complete 64-bit `Drivers32` key, and writes the validated rollback state.
10. It starts a detached watchdog and requires a ready receipt bound to the state path, child PID, and exact runtime hash before mutation.
11. It deletes only the `midi` value and requires a fresh 64-bit MIDI probe to equal the baseline minus exactly one GS Synth entry.
12. It waits for a new `eqgame.exe` and current-run fatal or character-select log markers.
13. It restores the original `REG_SZ` value and requires a fresh process to report the exact duplicate-aware baseline MIDI list—no missing or unexpected entries.
14. It records success/failure and restoration receipts, then gives the player one explicit final result.

## Result and exit-code contract

The elevated launch path uses these exit codes so the normal CMD window can report a truthful result after the UAC process closes:

| Exit | Meaning |
|---:|---|
| `0` | EQL reached character select and parent restoration verification passed |
| `1` | The elevated run stopped before a temporary transaction was confirmed |
| `2` | EQL did not reach character select, but parent restoration verification passed |
| `3` | A temporary transaction began and parent restoration verification did not pass |

Exit `3` does not claim that the watchdog failed. It tells the player that the parent could not verify restoration and directs them to `Emergency Restore Windows MIDI.cmd`.

## Recovery model

The rollback state records the exact registry view/path/name/value/type, baseline MIDI names, parent PID plus start time, deadline, runtime hash, and transaction status.

- Normal success, launch failure, timeout, and Ctrl+C enter the parent restoration loop.
- A detached watchdog restores after parent loss or deadline expiry.
- The next live or emergency-recovery run scans only validated active state receipts.
- Recovery refuses a different registry value, malformed state, wrong path/view/type, or unexpected protected storage.
- Restoration is idempotent when the exact baseline registry value is already present.

Protected artifacts live under:

```text
C:\ProgramData\EQL-GS-Synth-Workaround\
```

The directory is owned by Administrators, denies inherited write access to normal users, and rejects reparse points.

## Exact-byte and UAC trust chain

The unsigned readable-source design intentionally avoids a hidden compiled binary while preserving one immutable run identity:

1. The CMD wrapper reads and hashes the source bytes before PowerShell parses them as the trusted entry.
2. Normal `Launch`, `Check`, and `Recover` reject direct `-File` entry without those trusted bytes.
3. The original digest flows through compatibility checks and LaunchPad startup.
4. The encoded elevated bootstrap compares current source bytes with that original digest before parsing them.
5. Elevated mode stages the same bytes in protected ProgramData and verifies their hash.
6. Probe and watchdog child processes execute only that protected staged file with the same expected hash.

The separately published release ZIP checksum remains the package-level trust root.

## Package contents

```text
Launch EQL Audio Fix.cmd
Emergency Restore Windows MIDI.cmd
EQL-Audio-Fix.ps1
README.md
TECHNICAL.md
SECURITY.md
LICENSE
CHECKSUMS-SHA256.txt
```

The two CMD files are intentionally separate entry buttons. They share no registry, transaction, watchdog, or restoration implementation; those owners remain in the single PowerShell runtime.

## Local evidence and privacy

Transaction folders contain a registry export, state/receipt JSON, launcher/watchdog logs, the selected LaunchPad path, signer metadata, and MIDI-output names. Review them before sharing. Paths and device names may identify the local setup; full transaction folders and unreviewed crash dumps should not be posted publicly.

The workaround does not upload evidence or make network requests.

## Mechanism evidence

A preserved x64 minidump for the target signature recorded a `0xc0000005` null read in `C:\Windows\System32\wdmaud.drv`. Microsoft public symbols resolved the first unwind path to:

```text
CMicrosoftGSWavetableSynth::LoadDLSFile
  → CWasapiRenderer::Initialize
  → wdmaud.drv null vtable read (RCX = 0)
```

On the original affected PC, watchdog-backed GS Synth isolation repeatedly passed `Sound=1` launches with audible game audio and exact restoration. Removing isolation later allowed the same cold-launch `#630` to recur; reinstating isolation passed again.

## RC6 operating evidence

The exact published RC6 ZIP completed the guarded path on the original affected PC: signed LaunchPad validation, UAC handoff, watchdog readiness, GS Synth isolation, `Sound Manager loaded`, character select, success receipt, exact registry restoration, and restoration of all four original MIDI outputs. EQL remained alive and responsive through a delayed-fatal check. Audible output was not independently confirmed during that specific remote-access run.

Five later launches used the same published RC6 script hash. Across six RC6 runs from August 24–27, 2026:

- 6/6 reached character-select initialization;
- 6/6 recorded `Outcome: success`;
- 6/6 restored the observed exact baseline MIDI-output list;
- parent and watchdog restoration confirmation passed every time;
- no run required next-run recovery; and
- GS Synth isolation lasted 33.6–63.6 seconds (47.7-second median).

These are first-party results from one affected environment, not another-PC field adoption.

## RC7 verification contract

Because RC7 changes runtime bytes, it must not inherit RC6's release acceptance automatically. Before publication, verify the exact source and exact prepared ZIP through:

- Windows PowerShell 5.1 AST parsing;
- direct-entry and wrong-hash refusal;
- exact wrapper `--check-only` execution;
- 64-bit fresh-process MIDI probing;
- duplicate-aware exact-list regressions, including duplicates, missing entries, unexpected extras, and case/order changes;
- LaunchPad zero/one/multiple/wrong-path process branches;
- watchdog readiness and synthetic restoration from an exact baseline;
- prior `state-v1` recovery compatibility;
- safe ZIP paths, internal checksums, and clean extraction;
- before/after registry type/value, process, service, and protected-state checks; and
- one exact-package live guarded launch on the affected PC, with another-PC confirmation still pending.

A release remains a prerelease until another affected PC reports matching-signature live results.

## Security reporting

Read [`SECURITY.md`](SECURITY.md) and use [private vulnerability reporting](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new) for privilege-boundary, rollback, tampering, registry, path-selection, or code-execution concerns.
