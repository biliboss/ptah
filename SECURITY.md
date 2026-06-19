# Security

## Reporting a vulnerability

Use [GitHub's private security advisory](https://github.com/biliboss/ptah/security/advisories/new) flow. Do not file a public issue.

Include:
- Affected version (`ptah --version` output)
- Reproduction steps
- Impact / threat model
- Suggested fix (if you have one)

We will acknowledge within 7 days and aim for a fix or mitigation within 30 days for high-severity issues.

## Threat model

ptah runs as a per-user macOS daemon with no network listener:

- **IPC**: UNIX socket at `~/.cache/ptah/sock`, mode 0700. Only the owning user can connect. No authentication beyond filesystem perms.
- **Persistence**: SQLite file at `~/.cache/ptah/queue.db`. Texts the user enqueued are stored in plaintext.
- **Auto-start**: launchd LaunchAgent runs as the user, no privilege escalation.
- **Child process**: `/usr/bin/say` and (optionally) libpiper.dylib are invoked with user-controlled text. Text is passed via `argv` to `say` and via libpiper's C API to piper. Both should be safe against shell injection (no shell), but unvalidated text reaching `say` could exercise speech engine bugs.
- **Voice models**: `pt_BR-faber-medium.onnx` is downloaded by `scripts/fetch-voice.sh` over HTTPS from the canonical Piper voices repo. No checksum pinning yet (TODO).
- **libpiper**: linked from `vendor/piper1-gpl/libpiper/dist/lib/libpiper.dylib`, which ptah builds locally via CMake. No prebuilt binary is shipped.

## Out of scope

- macOS itself (`say`, launchd, CoreAudio).
- Network attacks (no network listener).
- Vulnerabilities in voice models or upstream libpiper.
- Pre-auth scenarios where an attacker already has the user's filesystem access.

## Known caveats

- Voice ONNX is not checksum-pinned (v1.1+).
- The Formula tarball URL/sha256 are placeholders until v1.0 release.
- launchd plist generator does not auto-inject `PTAH_PIPER=1` — users patch manually.
