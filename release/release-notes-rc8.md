# EQL audio-login crash workaround — v1.0.0-rc8

**Release candidate — not a universal #630 fix.** Download the ZIP attached to this release, not GitHub's generated Source code downloads. The previous RC6 release remains available unchanged.

## Who this is for

EQL crashes after server selection, around `Sound Manager loaded`, with `Fatal error occurred in mainthread! (Release Client #630)`, and `Sound=0` avoids the crash but removes game audio. This is a community workaround for that specific audio-initialization signature—not every #630 crash or an official game fix.

## How to use the RC8 package

1. Extract the complete `EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip`.
2. Close EQL and the Daybreak LaunchPad.
3. Double-click **Launch EQL Audio Fix.cmd** and approve the **Windows PowerShell** UAC prompt.
4. Wait for **Click PLAY normally**, then click PLAY in the official LaunchPad.
5. Keep the command window open until its final result.

After an interruption, or if Windows MIDI restoration cannot be verified, use **Emergency Restore Windows MIDI.cmd**. Preserve a refusal message rather than bypassing validation or deleting transaction records.

## Improvements over RC6 and the unpublished RC7 candidate

- MIDI probes now have an enforced timeout and drain stdout/stderr concurrently, preventing a hung probe or full error pipe from defeating the timeout.
- Failed or malformed probe results are rejected instead of being treated as MIDI-device evidence.
- Emergency recovery remains retryable until fresh restoration verification succeeds.
- Parent, watchdog, and emergency recovery require the same exact duplicate-aware MIDI-output baseline; GS Synth alone is not sufficient proof.
- Unreadable or malformed recovery records fail visibly instead of being silently skipped.
- EQL detection is bound to the selected installation, process ID, and start time. The pre-launch process baseline is captured before isolation.
- The guide clarifies when to click PLAY and when the emergency recovery button is required.

The existing narrow GS Synth isolation mechanism remains unchanged. The workaround does not stop Wave Link/audio services, change audio defaults, install drivers or persistence, modify game files, or upload logs.

## Verification and limits

The candidate passed 25/25 dependency-free regression cases against both repository source and clean ZIP extraction. The recorded audit also passed 16 source/build/extraction/read-only verification gates. Synthetic checks are not a substitute for a live launch.

On September 4, 2026 (original tester's local date), this exact ZIP passed an approved live launch on the original affected PC. The tester confirmed login with audible game audio. Protected receipts and independent readback confirmed character-select success with `Sound=1`, exact registry value/type and all four baseline MIDI outputs restored, parent and watchdog restoration, inactive transaction completion, and watchdog exit. The selected EQL process remained responsive without a #630 fatal in its current log during the follow-up.

Wave Link and Windows audio services were running. Separate Stream Mix/OBS audible routing was not verified. Another affected PC has not supplied RC8 field acceptance; the intended release remains a candidate, not a universal compatibility or security guarantee.

## Exact accepted artifact

- ZIP: `EQL-Audio-Crash-Workaround-v1.0.0-rc8.zip`
- ZIP SHA-256: `b7815524bdc4fa088b71dd521e776c369d8220b129501649ccb8caef1be94df3`
- Runtime SHA-256: `18622f613f15bf18c090e4460903ab26784aa972f68e92abec2871dfebd91aa1`

**Documentation timing:** the ZIP is the unchanged live-tested artifact. Its bundled README and technical guide were frozen before that test and conservatively describe live acceptance as pending. The later result is documented here and in the updated repository guide; the tested ZIP was not silently rebuilt to update those statements. Runtime and CMD-wrapper bytes match the reviewed candidate.

## Feedback and privacy

Report the exact version, whether the symptom matched, final launcher message, whether game audio worked, and whether normal audio outputs remained usable. Another-PC success is useful evidence, but a generic “worked” reply is not complete restoration proof.

- [Quick success report](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=quick-success.yml)
- [Failure or detailed field report](https://github.com/alphablueofficial/eql-audio-crash-workaround/issues/new?template=field-test.yml)
- [Private security report](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new)

Review logs before sharing. Do not publish credentials, tokens, full transaction folders, or unreviewed crash dumps.
