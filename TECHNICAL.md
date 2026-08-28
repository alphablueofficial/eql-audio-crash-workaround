# Technical design, safety, and evidence

This document contains the implementation detail moved out of the player-first [`README.md`](README.md). It describes the exact published `v1.0.0-rc6` release.

## Scope

The workaround targets one observed EverQuest Legends launch signature:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

A strong confirmation canary is that `Sound=0` avoids the crash while removing game audio. Other `#630` sequences, authentication/server failures, LaunchPad patching, ordinary gameplay crashes, and private-instance failures are outside scope.

## Portable but fail-closed

| Setup | RC6 behavior |
|---|---|
| EQL on another fixed drive | Searches common EQL locations on all fixed drives |
| Custom EQL location | Uses an EQL desktop shortcut when available or opens a file picker |
| Multiple installations | Requires the player to select one rather than guessing |
| No Wave Link | Works without it; Wave Link is not a dependency |
| VoiceMeeter, Sonar, VB-Cable, OBS, or other virtual audio | Leaves it unchanged |
| Additional physical or virtual MIDI outputs | Allows them; isolation must leave every baseline output except GS Synth present, and restoration must bring every baseline output back. RC6 does not reject unrelated outputs that appear later. |
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

During a live RC6 launch:

1. `Launch EQL Audio Fix.cmd` invokes the built-in 64-bit Windows PowerShell path.
2. The wrapper reads the PowerShell source bytes once, computes SHA-256, and executes those exact bytes from memory.
3. At normal privilege, the script checks the supported registry/MIDI baseline, validates the selected `LaunchPad.exe`, and opens that signed launcher at medium integrity.
4. After UAC, the encoded bootstrap requires the source to match the immutable entry digest before parsing elevated code.
5. The elevated phase creates or validates administrator-owned, non-reparse ProgramData storage and stages the exact trusted runtime bytes there.
6. Any valid prior active transaction is recovered before a new launch begins.
7. The running LaunchPad path, signature, product metadata, and integrity are revalidated.
8. The script requires exactly one freshly enumerable Microsoft GS Wavetable Synth output.
9. It creates a unique transaction folder, exports the complete 64-bit `Drivers32` key, and writes validated rollback state.
10. It starts a detached watchdog and requires a ready receipt bound to the state path, child PID, and exact runtime hash before mutation.
11. It deletes only the `midi` value and requires a fresh 64-bit MIDI probe to equal the baseline minus exactly one GS Synth entry.
12. It waits for a new `eqgame.exe` and current-run fatal or character-select log markers.
13. It restores the original `REG_SZ` value and requires a fresh process to report every baseline MIDI output again, including GS Synth. RC6 does not reject unrelated outputs that appeared later.
14. It records the outcome and restoration receipt, then reports the result to the player.

## Recovery model

The rollback state records the exact registry view/path/name/value/type, parent PID plus start time, deadline, runtime hash, and transaction status.

- Normal success, launch failure, timeout, and Ctrl+C enter the parent restoration loop.
- A detached watchdog restores after parent loss or deadline expiry.
- The next live or recovery run scans only validated active state receipts.
- Recovery refuses a different registry value, malformed state, wrong path/view/type, or unexpected protected storage.
- Restoration is idempotent when the exact baseline registry value is already present.

Protected artifacts live under:

```text
C:\ProgramData\EQL-GS-Synth-Workaround\
```

The directory is administrator-owned, denies inherited write access to normal users, and rejects reparse points.

## Exact-byte and UAC trust chain

The unsigned readable-source design avoids a hidden compiled executable while preserving one immutable run identity:

1. The CMD wrapper reads and hashes the source bytes before PowerShell parses them as the trusted entry.
2. Normal `Launch`, `Check`, and `Recover` reject direct `-File` entry without those trusted bytes.
3. The original digest remains bound through compatibility checks and LaunchPad startup.
4. The encoded elevated bootstrap compares current source bytes with the original digest before parsing them.
5. Elevated mode stages the same bytes in protected ProgramData and verifies their hash.
6. Probe and watchdog child processes execute only the protected staged file with the same expected hash.

The separately published release ZIP checksum is the package-level trust root:

```text
cd4df8494bd766590f2235fee2435df97c75402269b475fc89fb83f0bb885f74
```

## Published RC6 package contents

```text
Launch EQL Audio Fix.cmd
Restore Windows MIDI.cmd
EQL-Audio-Fix.ps1
README.md
SECURITY.md
LICENSE
CHECKSUMS-SHA256.txt
```

This `TECHNICAL.md` file and the simplified default-branch README were added as a documentation-only update. The published RC6 tag, ZIP, checksum, and package contents were not changed; the README inside that immutable ZIP remains the release-time version.

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

On the original affected PC, watchdog-backed GS Synth isolation repeatedly passed `Sound=1` launches with audible game audio and restoration. Removing isolation later allowed the same cold-launch `#630` to recur; reinstating isolation passed again.

## RC6 operating evidence

The exact GitHub-hosted RC6 ZIP completed the guarded path on the original affected PC: signed LaunchPad validation, UAC handoff, watchdog readiness, GS Synth isolation, `Sound Manager loaded`, character select, success receipt, exact registry restoration, and restoration of all four original MIDI outputs. EQL remained alive and responsive through a delayed-fatal check. Audible output was not independently confirmed during that specific remote-access run.

Five later launches used the same published RC6 script hash. Across six RC6 runs from August 24–27, 2026:

- 6/6 reached character-select initialization;
- 6/6 recorded `Outcome: success`;
- 6/6 restored the observed baseline MIDI outputs;
- parent and watchdog restoration confirmation passed every time;
- no run required next-run recovery; and
- GS Synth isolation lasted 33.6–63.6 seconds (47.7-second median).

These are first-party results from one affected environment, not another-PC field adoption. RC6 remains a prerelease until another affected PC reports matching-signature live results.

## Security reporting

Read [`SECURITY.md`](SECURITY.md) and use [private vulnerability reporting](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new) for privilege-boundary, rollback, tampering, registry, path-selection, or code-execution concerns.
