# EverQuest Legends #630 audio-login workaround

A one-button, open-source workaround for one specific **EverQuest Legends** crash:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

> **Status:** `v1.0.0-rc5` release candidate. The underlying GS Synth isolation mechanism has repeated live evidence on one affected PC. The exact RC5 package has deterministic non-mutating and adversarial verification, but has not completed a new live UAC/EQL launch. Additional affected-player confirmation is still needed. This is not a universal fix for every `#630` crash.

## Is this for you?

This workaround is a reasonable test if:

- EQL reaches server select and then crashes during audio initialization;
- the current-run `Logs\dbg.txt` reaches approximately `Sound Manager loaded` immediately before the fatal; and
- setting `Sound=0` lets the game continue, but with no game audio.

It is **not** intended for:

- Error 1017, authentication failures, or server timeouts;
- LaunchPad patching problems;
- crashes during ordinary gameplay;
- a stuck or failed private instance; or
- a different `Release Client #630` sequence.

If the compatibility check does not recognize your PC, the workaround stops instead of guessing.

## Quick start

### 1. Download the correct file

Open the [`v1.0.0-rc5` release page](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc5) and download:

```text
EQL-Audio-Crash-Workaround-v1.0.0-rc5.zip
```

Download the matching `.sha256.txt` file if you want to verify the ZIP. Do **not** use GitHub's automatically generated **Source code** ZIP; it is not the prepared player package.

### 2. Extract the whole ZIP

Do not run the files from inside the ZIP preview. Extract the complete folder somewhere you can find it.

### 3. Close EQL and LaunchPad

`eqgame.exe` must not already be running. Close the official Daybreak LaunchPad as well; the workaround will validate and reopen it.

### 4. Run the launcher

Double-click:

```text
Launch EQL Audio Fix.cmd
```

If more than one EQL installation is detected, select the `LaunchPad.exe` you actually use. The selected launcher must pass Daybreak signature and product checks.

### 5. Approve UAC, then click PLAY

The official LaunchPad opens at normal user privilege **before** the UAC prompt. Approve the Windows PowerShell UAC prompt, return to LaunchPad, and click **PLAY** normally.

### 6. Keep the command window open

Leave the small command window open while EQL starts. The workaround waits for character-select initialization or a fatal/timeout, restores Windows MIDI, verifies that restoration, and reports the result.

There is nothing to install or configure. RC5 requires 64-bit Windows and the built-in 64-bit Windows PowerShell 5.1.

## What you should see

A normal run looks like this:

1. A compatibility check passes without changing the system.
2. The signed Daybreak LaunchPad opens normally.
3. Windows asks for administrator approval for **Windows PowerShell**.
4. The command window tells you to click **PLAY**.
5. EQL starts while Microsoft GS Wavetable Synth is temporarily hidden.
6. The command window restores Windows MIDI and reports whether verification passed.

If a prerequisite, launcher identity, MIDI-device comparison, watchdog check, or restoration check is unexpected, the run stops rather than forcing the change.

## What it does—in plain English

The target crash was localized to Windows initializing **Microsoft GS Wavetable Synth** through `wdmaud.drv`.

For the short period while EQL starts, the workaround:

1. verifies the PC has the exact supported Windows MIDI registration;
2. validates and opens the official signed Daybreak LaunchPad;
3. saves the original Windows registry state;
4. starts an independent restoration watchdog;
5. temporarily hides only Microsoft GS Wavetable Synth;
6. verifies that every other MIDI output stayed present;
7. waits for EQL to reach character-select initialization or fail; and
8. restores and re-verifies the original Windows MIDI state.

The only temporary system change is this one 64-bit registry value:

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32
midi = wdmaud.drv    (REG_SZ)
```

## Different installs and audio setups

RC5 is not tied to the original PC's installation path or audio setup.

| Your setup | What RC5 does |
|---|---|
| EQL is installed on another fixed drive | Searches common EQL locations on all fixed drives |
| EQL is in a custom location | Uses an EQL desktop shortcut when available or opens a file picker |
| More than one EQL installation exists | Asks you to select the one you use instead of guessing |
| Wave Link is not installed | Works without it; Wave Link is not a dependency |
| VoiceMeeter, Sonar, VB-Cable, OBS, or other virtual audio is installed | Leaves it alone |
| Additional virtual or physical MIDI outputs exist | Allows them, but requires the before/after list to stay unchanged except for GS Synth |
| The Windows MIDI registration is different | Stops without changing it |
| Daybreak changes its launcher certificate identity | Stops until the project is reviewed and updated |

This is intentionally **portable but fail-closed**. It should not be described as working on literally every PC.

## What it does not change

It does **not**:

- modify, patch, inject into, or redistribute EQL files;
- automate login, server selection, character selection, or gameplay;
- stop or reconfigure Wave Link, VoiceMeeter, Sonar, VB-Cable, OBS, or other virtual audio software;
- change Windows playback or recording defaults;
- stop Windows audio or MIDI services;
- replace, disable, or copy `wdmaud.drv`;
- install a driver, service, scheduled task, startup item, or application;
- make network requests or upload logs; or
- read EQL credentials or account tokens.

## Why UAC appears

The temporary registry value is under `HKEY_LOCAL_MACHINE`, so Windows requires administrator approval.

The elevated phase does **not** launch EQL. It performs the bounded registry transaction and restoration checks. The already-open, signed Daybreak LaunchPad starts EQL at normal user privilege.

The package contains unsigned readable PowerShell rather than a signed compiled executable. The CMD button uses `ExecutionPolicy Bypass` only for that PowerShell process; it does not change the machine's saved execution policy.

## Safety and recovery

Normal success, EQL failure, timeout, Ctrl+C, or parent-process loss all trigger restoration. The detached watchdog identifies its parent by both process ID and process start time.

Protected backup, state, runtime, and receipt files are stored under:

```text
C:\ProgramData\EQL-GS-Synth-Workaround\
```

That directory is administrator-owned, rejects reparse points, and is read-only to normal users.

### If the PC loses power or the launch is interrupted

After Windows returns, double-click:

```text
Restore Windows MIDI.cmd
```

It restores only a recorded active transaction and refuses malformed or unexpected state. Do not manually force the registry change if recovery reports an error.

## Optional: check compatibility without UAC

Technically comfortable users can open Command Prompt in the extracted folder and run:

```bat
"Launch EQL Audio Fix.cmd" --check-only
```

This uses the CMD bootstrap to hash and parse the exact PowerShell script, then checks 64-bit Windows, the registry baseline, GS Synth, and current MIDI outputs. It validates `LaunchPad.exe` only when exactly one candidate can be identified automatically; zero or multiple candidates are reported without opening the file picker in check-only mode.

This command does not verify every file in the ZIP or `CHECKSUMS-SHA256.txt`. Use the ZIP checksum procedure below for package-level verification.

## Verify the downloaded ZIP

Every release includes a ZIP checksum file. On Windows, you can also calculate the hash yourself from Command Prompt:

```bat
certutil -hashfile "EQL-Audio-Crash-Workaround-v1.0.0-rc5.zip" SHA256
```

Compare the result with:

```text
EQL-Audio-Crash-Workaround-v1.0.0-rc5.zip.sha256.txt
```

Only run the package if the values match and you obtained it from this repository's release page.

## Troubleshooting

### The compatibility check stops

Do not force the registry change. Preserve the exact error message and the current-run `Logs\dbg.txt` sequence, then use the [RC field-test form](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml).

### A file picker opens

Select the official EverQuest Legends `LaunchPad.exe` that you normally use. RC5 opens the picker when it cannot identify one installation uniquely.

### The game still crashes

The watchdog should restore Windows MIDI. Preserve:

- the exact command-window result;
- the current EQL `Logs\dbg.txt`; and
- the newest transaction folder name under `C:\ProgramData\EQL-GS-Synth-Workaround\Transactions\`.

Review files before posting: local installation paths and MIDI-device names can identify your setup. Do not post credentials, tokens, unreviewed crash dumps, or a full transaction folder publicly.

### Restoration does not report PASS

Run `Restore Windows MIDI.cmd` from the same unmodified release folder. If it also stops, preserve the exact message and report it instead of manually editing the registry.

## Report results or security concerns

- Use the [RC field-test form](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml) for compatibility and live-launch results from another affected PC.
- Use [private vulnerability reporting](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new) for privilege-boundary, rollback, tampering, registry, or code-execution concerns.
- Read [SECURITY.md](SECURITY.md) before sharing sensitive technical evidence.

Useful field-test results include:

- Windows version and architecture;
- EQL installation location;
- relevant virtual audio and MIDI software;
- the original `dbg.txt` crash sequence;
- compatibility result;
- whether character select loaded with audible game audio; and
- whether exact restoration reported PASS.

## Trust and source review

The package contains no compiled project executable. The implementation is one readable [`EQL-Audio-Fix.ps1`](EQL-Audio-Fix.ps1) file plus two CMD buttons:

```text
Launch EQL Audio Fix.cmd
Restore Windows MIDI.cmd
EQL-Audio-Fix.ps1
README.md
SECURITY.md
LICENSE
CHECKSUMS-SHA256.txt
```

The CMD launcher reads the script's raw bytes once, hashes them, and executes those exact bytes from memory. Direct normal `-File` entry is rejected. The initial digest remains bound through compatibility checks, LaunchPad startup, UAC, protected staging, watchdog, and MIDI-probe child processes. Changed disk bytes are rejected before elevated parsing or registry mutation.

## Technical transaction sequence

During a live launch, RC5:

1. The CMD bootstrap explicitly invokes the built-in 64-bit Windows PowerShell and executes the hash-bound script bytes from memory.
2. At normal user privilege, the script checks the supported 64-bit registry/MIDI baseline, validates the selected `LaunchPad.exe`, opens it at medium integrity, and refuses an already-running elevated copy.
3. After UAC, the encoded bootstrap re-verifies the original entry digest before parsing the elevated script.
4. The elevated phase initializes protected, non-reparse ProgramData storage, stages and hashes the trusted runtime, and recovers any valid stale active transaction.
5. It revalidates the running LaunchPad process and requires exactly `midi=wdmaud.drv` as `REG_SZ`, in the 64-bit `Drivers32` view, plus exactly one freshly enumerable GS Synth output.
6. It creates the current transaction folder, exports the complete 64-bit `Drivers32` key, and writes protected rollback state.
7. It starts a detached watchdog and requires a valid ready receipt before registry deletion.
8. It removes only the exact `midi` value and requires a fresh 64-bit MIDI probe to equal the original duplicate-aware list minus only GS Synth.
9. It waits for new `eqgame.exe` and current-run character-select/fatal log markers.
10. It restores the original `REG_SZ` value and requires a fresh process to see the complete original MIDI-output list again.

## Technical evidence

A preserved x64 minidump for the target signature recorded a `0xc0000005` null read in `C:\Windows\System32\wdmaud.drv`. Microsoft public symbols resolved the first unwind path to:

```text
CMicrosoftGSWavetableSynth::LoadDLSFile
  → CWasapiRenderer::Initialize
  → wdmaud.drv null vtable read (RCX = 0)
```

On the original affected PC, watchdog-backed GS Synth isolation passed repeated `Sound=1` launches with audible game audio and exact restoration. Removing the isolation later allowed the same cold-launch `#630` to recur; reinstating isolation passed again. Those live runs establish evidence for the underlying isolation mechanism, not a live end-to-end test of the exact RC5 package topology.

RC5 retains release-candidate status because its exact final bytes have deterministic non-mutating and adversarial verification but have not completed a new live UAC/EQL launch. Live confirmation from additional affected PCs is still required.

This is a community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft fix.

## License

MIT. See [LICENSE](LICENSE).
