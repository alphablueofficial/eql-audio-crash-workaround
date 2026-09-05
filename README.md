# EverQuest Legends #630 audio-login workaround

Does **EverQuest Legends** crash just after server select while loading sound? This community workaround may let the game start normally **with audio still enabled**.

After the crash, open EQL's installation folder, open `Logs\dbg.txt` in Notepad, press **Ctrl+End**, and check the newest lines. Use this workaround only when they end around:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

A strong match is: setting `Sound=0` gets you past the crash, but leaves the game with no sound. This is **not** a universal fix for every #630 crash, Error 1017, login/server problems, LaunchPad patching, or ordinary gameplay crashes.

> **RC8 release candidate:** the exact ZIP passed an approved live launch on the original affected PC, with user-confirmed game audio and verified Windows MIDI restoration. Another-PC RC8 field acceptance and separate Stream Mix/OBS audible routing are not confirmed.

## Download

### [Download the ready-to-run v1.0.0-rc8 ZIP](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/download/v1.0.0-rc8/EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip)

Download **`EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip`**—not either of GitHub's generated **Source code** downloads.

> **Why the bundled guide looks different:** the live-tested ZIP is frozen. Its bundled README and technical guide contain the conservative pre-test status, including statements that RC8 is unpublished and awaiting its live test. This page and the [RC8 release notes](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc8) record the later result. The tested program files and ZIP were not replaced.

## Run the workaround

1. Right-click the downloaded ZIP and choose **Extract All**. Do not run it from inside the ZIP preview.
2. If you previously changed `Sound=1` to `Sound=0` in `eqclient.ini`, change it back to `Sound=1`. The workaround does not change this game setting for you.
3. Close both EQL and the Daybreak LaunchPad.
4. Open the extracted folder and double-click:

   ```text
   Launch EQL Audio Fix.cmd
   ```

5. If a file picker appears, select the official EQL `LaunchPad.exe` you normally use.
6. The official LaunchPad opens. Approve the UAC prompt for **Windows PowerShell**.
7. **Wait for “Click PLAY normally”**, then return to LaunchPad and click **PLAY**.
8. Keep the command window open until its final result. Confirm that game audio is audible.

A successful run ends with:

```text
SUCCESS - EQL reached character select and Windows MIDI was fully restored.
```

This is a **per-launch workaround**, not a permanent patch. Run the launch button each time you need to start EQL. It requires 64-bit Windows and the built-in Windows PowerShell 5.1; there is no installer or setup wizard.

### Different install or audio setup?

- EQL may be on another drive or in a custom folder. If the workaround cannot identify it automatically, it opens a file picker.
- If you have multiple EQL installations, select the official `LaunchPad.exe` for the installation you actually use.
- **Wave Link is not required.** Wave Link, VoiceMeeter, Sonar, VB-Cable, OBS, and other audio tools are left alone.
- Unexpected launcher identity, Windows MIDI state, watchdog readiness, or restoration results stop the run instead of forcing the change.

## What it changes

For only the short period while EQL starts, the workaround temporarily hides **Microsoft GS Wavetable Synth**. It saves the original state first and arms an independent restoration watchdog, then restores and freshly verifies the exact original MIDI-output list—no missing, replaced, or unexpected entries.

It does **not** modify or inject into EQL, automate login/gameplay, change playback or recording defaults, reconfigure audio software, stop audio/MIDI services, install a driver/service/task/startup item, make network requests, upload logs, or read EQL credentials.

The one temporary system change is the 64-bit `Drivers32\midi = wdmaud.drv` registry value. The full path, safety design, result codes, and evidence are in [TECHNICAL.md](TECHNICAL.md).

## If the PC loses power or restoration cannot be verified

After Windows returns, open the same extracted folder and double-click:

```text
Emergency Restore Windows MIDI.cmd
```

Normal success, game failure, timeout, Ctrl+C, or parent-process loss already trigger restoration. Use the emergency button after an interruption or when the final message says restoration could not be verified. If normal launch reports an absent registry value after an interruption, use emergency recovery first.

Recovery restores only a validated active transaction and keeps it active until the exact recorded MIDI-output baseline is verified. If it refuses unexpected state or changed devices, reconnect the original MIDI devices if possible, save the exact message, and report it. **Do not force the registry change or delete transaction records.**

## Get help or report your result

- **It worked:** [send a quick success report](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=quick-success.yml).
- **It stopped, crashed, had no sound, or did not restore:** [open the detailed field-test form](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml).
- **Security concern:** [report it privately](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new).

Preserve the final command-window message, current `Logs\dbg.txt`, and newest transaction-folder name under `C:\ProgramData\EQL-GS-Synth-Workaround\Transactions\`. Review text before sharing: installation paths and device names may identify your setup. Never post credentials, tokens, unreviewed crash dumps, or full transaction folders publicly.

## Optional checks

### Check compatibility without UAC or changes

Open Command Prompt in the extracted folder and run:

```bat
"Launch EQL Audio Fix.cmd" --check-only
```

This checks architecture, the registry baseline, fresh MIDI enumeration, and an automatically identifiable signed LaunchPad. Zero or multiple launcher candidates are reported without opening a picker. It is not a live launch or a check of every packaged file.

### Verify the ZIP

In the folder containing the downloaded ZIP, run:

```bat
certutil -hashfile "EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip" SHA256
```

Expected SHA-256:

```text
b7815524bdc4fa088b71dd521e776c369d8220b129501649ccb8caef1be94df3
```

Compare with the [matching checksum file](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/download/v1.0.0-rc8/EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip.sha256.txt).

## Why UAC appears

The temporary registry value is under `HKEY_LOCAL_MACHINE`, so Windows requires administrator approval. The prompt names **Windows PowerShell** because this is readable unsigned source, not a hidden compiled executable. The elevated phase does not launch EQL; the signed Daybreak LaunchPad starts it at normal user privilege.

`ExecutionPolicy Bypass` applies only to that launched PowerShell process. It does not change your saved execution policy.

## More detail

- [Technical design, recovery, and evidence](TECHNICAL.md)
- [Maintainer regression tests](tests/README.md)—not included in the player ZIP
- [Security policy](SECURITY.md)
- [RC8 release notes](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc8)
- [Previous RC6 release](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc6), preserved unchanged

This is a community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft fix. It remains a prerelease; broader field acceptance and stable promotion are separate decisions.

## License

MIT. See [LICENSE](LICENSE).
