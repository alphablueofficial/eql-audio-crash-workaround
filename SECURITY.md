# Security Policy

## Supported version

Only the newest GitHub prerelease is supported. Older release candidates may contain known issues and must not be redistributed.

## Report a vulnerability privately

Please use [GitHub private vulnerability reporting](https://github.com/alphablueofficial/eql-audio-crash-workaround/security/advisories/new) for any suspected privilege-boundary, rollback, tampering, registry, path-selection, or code-execution issue.

Do not open a public issue containing exploit instructions, proof-of-concept payloads, private paths, or transaction files.

Include, when safe:

- affected release version and ZIP SHA-256;
- Windows version and architecture;
- the exact step where the issue occurs;
- whether UAC was approved;
- whether the registry value was restored;
- a minimal reproduction with secrets and personal paths removed.

## Safety boundary

This is an unsigned community workaround, not an official Daybreak, Game Jawn, Elgato, or Microsoft product. It intentionally fails closed on unknown configurations and does not claim to protect a package that was replaced before the user verified its published release hash.

If Windows MIDI restoration is the immediate concern, run `Emergency Restore Windows MIDI.cmd` from the same unmodified release folder before collecting additional evidence.
