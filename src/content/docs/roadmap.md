---
title: Roadmap
description: v0.1 → v1.3 shipped 2026-06-03 in a single session. v1.2, v1.4, v1.5 in What's next.
---

## TL;DR

v0.1 → v1.0 shipped on **2026-06-03**, in one session, behind one KPI. v1.1 (multilingual code-switch) and v1.3 (cross-platform) landed the same day. Ten milestones, each with a published measurement.

v1.2, v1.4, v1.5 are scoped for marketing and engineering value in [What's next](/whats-next/).

## v0.1 → v1.3 — Shipped

Every milestone has a published baseline in [`_qa/`](https://github.com/biliboss/agent-tts/tree/main/_qa) and a section in the [Changelog](/changelog/).

| Milestone | Focus | Result | Date |
|-------|------|--------|------|
| **v0.1** | `say` direct, no daemon | spawn 0.8 ms, 415 KB binary | 2026-06-03 |
| **v0.2** | Daemon + UNIX socket + in-memory FIFO | round-trip ACK < 0.1 ms, 455 KB | 2026-06-03 |
| **v0.3** | SQLite WAL queue + `queue` / `skip` / `clear` | survives `kill -9`, 476 KB | 2026-06-03 |
| **v0.4** | launchd `daemon install \| uninstall \| status` | 10 ms install round-trip | 2026-06-03 |
| **v0.5** | Pt-BR preprocessor (cardinals, abbreviations, pauses) | 2-5 µs / msg, 26 unit tests | 2026-06-03 |
| **v0.6** | libpiper FFI baseline | piper init 400 ms, synth + WAV 100 ms warm | 2026-06-03 |
| **v0.7** | zaudio streaming + `--engine say\|piper` routing | piper synth warm **91 ms** | 2026-06-03 |
| **v1.0** | Universal binary + brew formula + GitHub Pages docs | universal 1.8 MB, host 918 KB | 2026-06-03 |
| **v1.1** | Multilingual: detect.zig + `--lang` + En Piper voice | 64/64 tests, host 897 KB, multi-piper boot 313 ms (Pt only) | 2026-06-03 |
| **v1.3** | Cross-platform — Linux espeak-ng + systemd + CI matrix | macOS green, Linux green on CI, Windows compile-only | 2026-06-03 |

## KPI delivered

Every milestone was measured against **time-to-first-audio (TTFA)**.

| Target | Acceptance | Measured |
|---|---|---|
| Warm daemon say | < 300 ms | round-trip 0.1 ms + spawn 0.8 ms + playback ✅ |
| Piper warm synth | < 1 s | **91 ms** ✅ (v0.7), 92.7 ms re-measured at v1.1 ✅ |
| Cold daemon boot | < 800 ms | pre-warm 280 ms + zaudio 79 ms + piper 373 ms = ~720 ms ✅ |
| Multi-piper boot (Pt only) | < 800 ms | pre-warm 255 ms + zaudio 54 ms + multi-piper 313 ms = ~622 ms ✅ |
| Lang detect per message | < 100 µs | informational, not captured this session |

Baselines: [`_qa/v0.1` … `_qa/v1.0`](https://github.com/biliboss/agent-tts/tree/main/_qa). Real audio-device dtruss not captured (SIP-on host); documented honestly in `_qa/v1.0-baseline.md`. v1.1 measurements live inline in the [Changelog](/changelog/).

## Installation

**macOS** (v1.0):

```bash
# Via tap (waiting for first signed release tarball):
brew tap biliboss/tap
brew install biliboss/tap/agent-tts

# From source today:
git clone https://github.com/biliboss/agent-tts.git
cd agent-tts
zig build -Doptimize=ReleaseFast
cp zig-out/bin/agent-tts /opt/homebrew/bin/

# Auto-start at login (launchd):
agent-tts daemon install
```

**Linux** (v1.3 — Debian/Ubuntu; adapt apt → dnf/pacman as needed):

```bash
sudo apt install libasound2 libsqlite3-0 espeak-ng
git clone https://github.com/biliboss/agent-tts.git
cd agent-tts
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/agent-tts /usr/local/bin/

# Auto-start at login (systemd user unit):
agent-tts daemon install
```

Build deps add `libasound2-dev libsqlite3-dev` if you compile yourself.

**Windows** (v1.3 best-effort): source compiles via `zig build` on `windows-latest`, runtime untested. `daemon install` deliberately errors out — run `agent-tts daemon` foreground or wire your own Startup folder shortcut.

Piper engine requires the vendor build (macOS + Linux; Windows untested):

```bash
./scripts/build-libpiper.sh
./scripts/fetch-voice.sh
zig build -Doptimize=ReleaseFast -Dwith-piper=true
```

Auto-start unit paths:
- macOS: `~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist`
- Linux: `~/.config/systemd/user/agent-tts.service`

## What's next (v1.2, v1.4, v1.5)

See [What's next](/whats-next/) for the marketing roadmap. Short version:

| | Theme | Headline |
|---|---|---|
| v1.2 | Streaming | First word before the last is written |
| v1.4 | Voice cloning | Your voice, your agent |
| v1.5 | MCP server | Native Claude Code voice — drop the shell-out |

## Locked nots

- No embedded voice model in the binary (breaks the SSD goal).
- No Windows runtime guarantee in v1.3 (code paths exist, untested).
- No parallel TTS (overlap = bad UX).
- No Cocoa / AVSpeechSynthesizer until `say` proves insufficient.
- No YAML config before v1.1 (YAGNI).
- No cloud sync, no usage telemetry, no account, no quota. Ever.
