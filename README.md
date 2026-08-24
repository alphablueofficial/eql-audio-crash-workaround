# EverQuest Legends audio-login workaround

A one-button, open-source workaround for one specific **EverQuest Legends** crash:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

This is intended for players who can reach server select but crash during audio initialization. A strong confirmation is that `Sound=0` lets the game continue, but removes game audio.

> **Status:** Release candidate. The underlying workaround is verified on one affected PC. Additional affected-player confirmations are still wanted.

## Download and use

1. Download the latest ZIP from [Releases](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/latest) and extract the whole folder.
2. Close EQL and LaunchPad.
3. Double-click **`Launch EQL Audio Fix.cmd`**.
4. Approve the Windows UAC prompt.
5. In the official EQL LaunchPad, click **PLAY** normally.
6. Leave the small command window open until it reports that Windows MIDI was restored.

That is the complete normal workflow. There is nothing to install or configure.

## What the workaround does

The crash dump for this failure localized the fault to the Windows **Microsoft GS Wavetable Synth** initialization path in `wdmaud.drv`. It did not show Elgato Wave Link code crashing.

During EQL startup, the launcher:

1. Checks that this PC has the exact expected 64-bit Windows registration:
   ```text
   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32
   midi = wdmaud.drv    (REG_SZ)
   ```
2. Verifies that Microsoft GS Wavetable Synth is currently visible and that no EQL process is already running.
3. Verifies the official `LaunchPad.exe` Authenticode signature, exact current Daybreak certificate subject, and Daybreak product metadata.
4. Opens the official LaunchPad **before UAC**, at normal user privilege.
5. After UAC, exports the complete 64-bit `Drivers32` key and creates protected rollback state.
6. Starts an independent restoration watchdog and requires its ready acknowledgement.
7. Temporarily removes only the 64-bit `midi=wdmaud.drv` value.
8. Starts a fresh 64-bit MIDI probe and requires the device list to equal the original list minus only Microsoft GS Wavetable Synth.
9. Waits for EQL to reach character-select initialization or report a fatal/timeout.
10. Restores the exact original `REG_SZ` value and verifies from a fresh process that the original MIDI outputs returned.

If any prerequisite or verification is different, it stops instead of guessing.

## What it does **not** do

It does not:

- modify, patch, inject into, or redistribute EQL files;
- automate login, server selection, character selection, or gameplay;
- stop or reconfigure Elgato Wave Link;
- change Windows playback or recording defaults;
- stop Windows audio or MIDI services;
- replace, disable, or copy `wdmaud.drv`;
- install a driver, service, scheduled task, startup item, or application;
- make network requests or upload logs;
- read EQL credentials or account tokens.

The only temporary system change is the one exact 64-bit registry value shown above.

## Why UAC is required

The value is under `HKEY_LOCAL_MACHINE`, so Windows requires administrator approval. The elevated phase does **not** launch EQL. It only manages the bounded registry transaction and restoration checks. The already-open, signed Daybreak LaunchPad starts EQL normally.

The UAC prompt identifies **Windows PowerShell** because this project ships readable scripts rather than a hidden executable.

## Safety and recovery

Normal success, EQL failure, timeout, Ctrl+C, or parent-process loss all trigger restoration. The watchdog binds to the parent process ID **and** process start time so PID reuse cannot postpone recovery.

Privileged state is stored under:

```text
C:\ProgramData\EQL-GS-Synth-Workaround\
```

That directory is administrator-owned, rejects reparse points, and is read-only to normal users.

If Windows loses power during the short launch transaction, run:

```text
Restore Windows MIDI.cmd
```

It restores only a recorded active transaction and refuses unexpected state.

## Trust and source review

The project intentionally contains no compiled executable. The two user-facing files are small CMD wrappers; all behavior is readable under [`support/`](support/).

For each GitHub release:

- download the release ZIP and its `.sha256.txt` file;
- compute the ZIP's SHA-256 locally if desired;
- compare it with the published hash before running.

The main script pins the exact watchdog and MIDI-probe hashes. Before elevated helper execution, it stages those exact bytes into protected ProgramData and verifies them again.

A future legitimate Daybreak certificate-subject change will fail closed until this project is reviewed and updated.

## When this will not help

Do not expect this workaround to fix:

- Error 1017 or authentication/server timeouts;
- a stuck or failed private instance;
- crashes during ordinary gameplay;
- LaunchPad patching problems;
- a different Release Client #630 crash sequence;
- a PC where the compatibility checks do not find the exact baseline.

## Troubleshooting

### The compatibility check stops

Do not manually force the registry change. Copy the exact error and your current-run `Logs\dbg.txt` sequence into a GitHub issue.

### LaunchPad is not found

The launcher opens a file picker. Select the official EverQuest Legends `LaunchPad.exe`.

### The game still crashes

The watchdog restores Windows MIDI. Preserve:

- the current EQL `Logs\dbg.txt`;
- the newest transaction folder under `C:\ProgramData\EQL-GS-Synth-Workaround\Transactions\`;
- whether the launcher reported successful restoration.

Review logs before posting because they can contain local installation paths and MIDI-device names. They do not contain saved EQL passwords or session tokens.

## Technical evidence

A preserved x64 minidump for the target signature recorded a `0xc0000005` null read in `C:\Windows\System32\wdmaud.drv`. Microsoft public symbols resolved the first unwind path to:

```text
CMicrosoftGSWavetableSynth::LoadDLSFile
  → CWasapiRenderer::Initialize
  → wdmaud.drv null vtable read (RCX = 0)
```

On the affected PC, watchdog-backed isolation passed repeated `Sound=1` launches with audible game audio and exact restoration. Removing the isolation later allowed the same cold-launch #630 to recur, after which reinstating the isolation passed again.

This remains a community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft fix.

## License

MIT. See [LICENSE](LICENSE).
