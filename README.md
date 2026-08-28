# Fix the EverQuest Legends #630 audio crash

Does **EverQuest Legends** crash just after server select while loading sound? This community workaround may let the game start normally **with audio still enabled**.

After the crash, open EQL's installation folder, open `Logs\dbg.txt` in Notepad, press **Ctrl+End**, and check the newest lines. Use this workaround only when they end around:

```text
Server selected → Sound Manager loaded →
Fatal error occurred in mainthread! (Release Client #630)
```

A strong match is: setting `Sound=0` gets you past the crash, but leaves the game with no sound.

> **Current release:** `v1.0.0-rc6` for 64-bit Windows. It completed 6/6 guarded launches on the original affected PC, including automatic Windows MIDI restoration. Confirmation from another affected PC is still needed.

## Download

### [Download the ready-to-run v1.0.0-rc6 ZIP](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/download/v1.0.0-rc6/EQL-Audio-Crash-Workaround-v1.0.0-rc6.zip)

Download **`EQL-Audio-Crash-Workaround-v1.0.0-rc6.zip`**—not either of GitHub's **Source code** downloads.

> **Why the README inside the ZIP looks different:** the tested RC6 ZIP is frozen and still contains its longer release-time README. This GitHub page is the current simplified guide; the tested program files and ZIP were not replaced.

## Run the fix

1. Right-click the downloaded ZIP and choose **Extract All**. Do not run it from inside the ZIP preview.
2. If you previously changed `Sound=1` to `Sound=0` in `eqclient.ini`, change it back to `Sound=1`. The workaround does not change this game setting for you.
3. Close both EQL and the Daybreak LaunchPad.
4. Open the extracted folder and double-click:

   ```text
   Launch EQL Audio Fix.cmd
   ```

5. If a file picker appears, select the official EQL `LaunchPad.exe` you normally use.
6. The official LaunchPad opens. Approve the UAC prompt for **Windows PowerShell**.
7. Return to LaunchPad and click **PLAY** normally.
8. Keep the command window open until it reports that Windows MIDI restoration **passed**.

The workaround installs nothing and has no setup wizard.

This is a **per-launch workaround**, not a permanent patch. Run `Launch EQL Audio Fix.cmd` each time you need to start EQL.

### Different install or audio setup?

- EQL may be installed on another drive or in a custom folder. If the workaround cannot identify it automatically, it opens a file picker.
- If you have multiple EQL installations, select the official `LaunchPad.exe` for the installation you actually use.
- **Wave Link is not required.** VoiceMeeter, Sonar, VB-Cable, OBS, and other audio tools are left alone.

## What a normal run looks like

1. The compatibility check passes.
2. The signed Daybreak LaunchPad opens.
3. Windows asks whether **Windows PowerShell** may make changes.
4. The command window tells you to click **PLAY**.
5. EQL reaches character select; confirm that game audio is audible.
6. The command window restores Microsoft GS Wavetable Synth and reports `PASS`.

If the PC, launcher, MIDI state, watchdog, or restoration result is unexpected, the workaround stops instead of guessing.

## Is this the right problem?

| Use this workaround when… | Do not use it for… |
|---|---|
| The crash happens after server select during audio initialization | Error 1017, login, authentication, or server problems |
| `dbg.txt` reaches `Sound Manager loaded` just before `#630` | LaunchPad patching problems |
| `Sound=0` avoids the crash but removes game audio | Ordinary gameplay crashes |
| You are on 64-bit Windows with built-in Windows PowerShell 5.1 | A different `Release Client #630` sequence |

## What it changes

For only the short period while EQL starts, the workaround temporarily hides **Microsoft GS Wavetable Synth**. It saves the original state first, starts an independent restoration watchdog, and then restores and freshly verifies that every original MIDI output—including GS Synth—is present again.

It does **not**:

- modify or inject into EQL;
- change your playback or recording defaults;
- reconfigure Wave Link, VoiceMeeter, Sonar, VB-Cable, OBS, or other audio software;
- stop Windows audio services;
- install a driver, service, scheduled task, startup item, or application;
- make network requests or upload logs; or
- read EQL credentials or account tokens.

The exact temporary Windows value and full safety design are documented in [TECHNICAL.md](TECHNICAL.md).

## If the PC loses power or restoration does not pass

After Windows returns, open the same extracted folder and double-click:

```text
Restore Windows MIDI.cmd
```

Normal success, game failure, timeout, Ctrl+C, or loss of the parent process already trigger automatic restoration. The recovery button is for an interrupted run or a result that did not report restoration `PASS`.

Recovery restores only a validated active transaction. If it refuses unexpected state, **do not manually edit the registry**—save the exact message and report it.

## Get help or report your result

- **It worked:** [send a quick success report](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=quick-success.yml)
- **It stopped, crashed, had no sound, or did not restore:** [open the detailed field-test form](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml)
- **Security concern:** [report it privately](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new)

Before posting, review the text you share. Installation paths and MIDI-device names may identify your setup. Never post credentials, tokens, unreviewed crash dumps, or a full transaction folder publicly.

## Optional safety checks

### Check compatibility without UAC or changes

Open Command Prompt in the extracted folder and run:

```bat
"Launch EQL Audio Fix.cmd" --check-only
```

### Verify the downloaded ZIP

Open Command Prompt in the folder containing the **downloaded ZIP**—usually your Downloads folder—then run:

```bat
certutil -hashfile "EQL-Audio-Crash-Workaround-v1.0.0-rc6.zip" SHA256
```

Expected SHA-256:

```text
cd4df8494bd766590f2235fee2435df97c75402269b475fc89fb83f0bb885f74
```

You can also download the [published checksum file](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/download/v1.0.0-rc6/EQL-Audio-Crash-Workaround-v1.0.0-rc6.zip.sha256.txt).

## Why UAC appears

The workaround must temporarily change one protected Windows MIDI registration, so Windows requires administrator approval. The UAC prompt names **Windows PowerShell** because the package is readable PowerShell source rather than a hidden compiled executable.

`ExecutionPolicy Bypass` applies only to the launched PowerShell process. It does not change the saved execution policy on your PC.

## More detail

- [Technical design, safety, recovery, and evidence](TECHNICAL.md)
- [Security policy and private reporting](SECURITY.md)
- [Full v1.0.0-rc6 release page](https://github.com/alphablueofficial/eql-audio-crash-workaround/releases/tag/v1.0.0-rc6)

This is an unsigned community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft fix. The release remains a prerelease until another affected PC confirms the matching crash and result.

## License

MIT. See [LICENSE](LICENSE).
