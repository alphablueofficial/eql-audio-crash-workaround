# EverQuest Legends #630 audio-login workaround

A one-button, open-source workaround for this specific **EverQuest Legends** crash:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

> **Status:** `v1.0.0-rc7` prerelease. RC7 preserves the guarded transaction used successfully for six consecutive `Sound=1` launches on the original affected PC, makes the final result unmistakable, requires an exact duplicate-aware MIDI restoration match, and gives emergency recovery a clearer name. Another affected PC still needs to confirm it. This is not a universal fix for every `#630` crash.

## Is this for you?

Try this only if:

- EQL crashes during audio initialization after server select;
- the current-run `Logs\dbg.txt` reaches approximately `Sound Manager loaded` before the fatal; and
- `Sound=0` avoids the crash but removes game audio.

It is not for Error 1017, authentication/server problems, LaunchPad patching, ordinary gameplay crashes, private-instance failures, or a different `#630` sequence.

## Quick start

1. Open the [`v1.0.0-rc7` release page](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc7) and download:

   ```text
   EQL-Audio-Crash-Workaround-v1.0.0-rc7.zip
   ```

   Do **not** use GitHub's generated **Source code** ZIP.

2. Extract the complete ZIP. Close EQL and the Daybreak LaunchPad.

3. Double-click:

   ```text
   Launch EQL Audio Fix.cmd
   ```

4. If asked, select the official EQL `LaunchPad.exe`. Approve the **Windows PowerShell** UAC prompt, return to LaunchPad, and click **PLAY** normally.

Keep the command window open until it reports a final result. There is nothing to install or configure. RC7 requires 64-bit Windows and the built-in 64-bit Windows PowerShell 5.1.

## Final results

A completed run ends with one of these messages:

```text
SUCCESS - EQL reached character select and Windows MIDI was fully restored.
```

```text
FAILED - EQL did not reach character select. Windows MIDI was fully restored.
```

```text
FAILED - Windows MIDI restoration could not be verified. Run Emergency Restore Windows MIDI.cmd.
```

`STOPPED` means the guarded run did not complete and no temporary change was confirmed. Preserve the exact message rather than forcing the registry change.

## What it changes

For the short period while EQL starts, the workaround temporarily hides only **Microsoft GS Wavetable Synth**, waits for character-select initialization or failure, then restores and freshly verifies the exact original duplicate-aware MIDI-output list.

The only temporary system change is this 64-bit registry value:

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32
midi = wdmaud.drv    (REG_SZ)
```

It validates the official signed Daybreak LaunchPad, saves rollback state, and arms an independent watchdog before deleting that value.

## What it does not change

It does **not**:

- modify, inject into, or redistribute EQL files;
- automate login, server/character selection, or gameplay;
- reconfigure Wave Link, VoiceMeeter, Sonar, VB-Cable, OBS, or other audio software;
- change Windows playback/recording defaults or stop audio/MIDI services;
- install a driver, service, task, startup item, or application;
- make network requests or upload logs; or
- read EQL credentials or account tokens.

## Emergency recovery

Normal success, EQL failure, timeout, Ctrl+C, or parent-process loss all trigger restoration. Protected rollback state is stored under:

```text
C:\ProgramData\EQL-GS-Synth-Workaround\
```

After power loss—or whenever the result says restoration was not verified—double-click:

```text
Emergency Restore Windows MIDI.cmd
```

It restores only a validated recorded active transaction. If it refuses unexpected state, do not manually force the registry change; preserve the exact error and report it.

## If something stops or fails

Preserve:

- the final command-window message;
- the current EQL `Logs\dbg.txt`; and
- the newest transaction-folder name under `C:\ProgramData\EQL-GS-Synth-Workaround\Transactions\`.

Review files before posting. Installation paths and MIDI-device names can identify your setup. Never post credentials, tokens, unreviewed crash dumps, or a full transaction folder publicly.

- Clean RC7 success: [quick success report](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=quick-success.yml)
- Stop, crash, missing audio, or restoration problem: [detailed field-test form](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml)
- Privilege, rollback, tampering, registry, or code-execution concern: [private vulnerability report](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new)

## Optional compatibility check

From Command Prompt in the extracted folder:

```bat
"Launch EQL Audio Fix.cmd" --check-only
```

This uses the real hash-verifying launcher path and checks Windows architecture, the registry baseline, fresh MIDI enumeration, and an automatically identifiable LaunchPad without UAC or mutation. Zero or multiple LaunchPad candidates are reported without opening a picker.

## Verify the ZIP

Download the matching `.sha256.txt` file, or calculate the ZIP hash:

```bat
certutil -hashfile "EQL-Audio-Crash-Workaround-v1.0.0-rc7.zip" SHA256
```

Run the package only if it matches `EQL-Audio-Crash-Workaround-v1.0.0-rc7.zip.sha256.txt` from this repository's release page.

## Why UAC and ExecutionPolicy Bypass appear

The bounded temporary value is under `HKEY_LOCAL_MACHINE`, so Windows requires administrator approval. The elevated phase does not launch EQL; the already-open signed Daybreak LaunchPad starts EQL at normal user privilege.

The package uses readable unsigned PowerShell. `ExecutionPolicy Bypass` applies only to that launched PowerShell process and does not change the machine's saved policy.

## Technical details and evidence

Read [`TECHNICAL.md`](TECHNICAL.md) for:

- supported and fail-closed configurations;
- the complete transaction and recovery sequence;
- exact-byte/UAC trust boundaries;
- package topology and privacy notes; and
- dump analysis, RC6 operating evidence, and the RC7 verification contract.

Read [`SECURITY.md`](SECURITY.md) before sharing sensitive evidence.

This is a community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft fix.

## License

MIT. See [LICENSE](LICENSE).
