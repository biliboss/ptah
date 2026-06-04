---
title: Roadmap
description: v0.1 → v1.5 shipped 2026-06-03 in a single session. Roadmap complete.
---

## TL;DR

v0.1 → v1.5 shipped on **2026-06-03**, in one session, behind one KPI. Thirteen milestones, each with a published measurement. Universal binary, brew tap, launchd + systemd auto-start, multilingual code-switch, sentence streaming, Linux/Windows code paths, voice cloning scaffold, and stdio JSON-RPC MCP server — all landed the same day.

The next slate (v1.6+) is unscheduled; see [What's next](/agent-tts/whats-next/).

## v0.1 → v1.5 — Shipped

Every milestone has a published baseline in [`_qa/`](https://github.com/biliboss/agent-tts/tree/main/_qa) and a section in the [Changelog](/agent-tts/changelog/).

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
| **v1.2** | Sentence chunking + pipelined synth/playback | long-input first-audio **41-52 ms** (down from ~3 s), gap median 0.02 ms | 2026-06-03 |
| **v1.3** | Cross-platform — Linux espeak-ng + systemd + CI matrix | macOS green, Linux green on CI, Windows compile-only | 2026-06-03 |
| **v1.4** | `voice clone` + `voice list` + XTTS-v2 Python sidecar | surface + dispatch + 40/40 tests; install/smoke deferred to v1.4.1 | 2026-06-03 |
| **v1.5** | MCP server: stdio JSON-RPC, 5 tools, native Claude Code voice | binary 993 KB (+115 KB), tools-only scope | 2026-06-03 |
| **v1.6** | Voice cloning ship-it: setup-voice-clone.sh validated, real Gabriel voice, `voice list` shows duration + rate, bench script | clone 23.4s, cold synth 26.4s → 4.3s audio, 67/67 tests, 5 install blockers fixed | 2026-06-03 |
| **v1.7** | Streaming text input: `agent-tts stream` + `say_stream` MCP tool + incremental chunker | 166/166 tests, end-to-end CLI + MCP green, latency bench wired | 2026-06-03 |
| **v1.8** | SSML 1.1 subset: `<emphasis>` / `<break>` / `<prosody>` / `<say-as>` for `say` + Piper | parse < 0.2 µs / 280 chars, +16 ssml tests + 5 ipc tests | 2026-06-03 |
| **v1.9** | Web playground scaffold: Astro widget + voice picker + Speak button + 501 stub | scaffold only — WASM Piper synth deferred to v1.9.1 | 2026-06-03 |
| **v1.10** | Menubar UI: SwiftUI status item + queue + Skip/Clear + voice picker | 911 Swift LOC, 321 KB .app binary | 2026-06-03 |
| **v1.10.1** | Playground externalize JS/CSS + menubar AppIcon.icns + live screenshot | external `public/playground/widget.{js,css}`; sips+iconutil pipeline | 2026-06-03 |
| **v1.10.2** | History + pause/resume/replay + floating SwiftUI player + 4 new MCP tools | 17/17 socket-parser cases; 10 MCP tools total | 2026-06-03 |
| **v1.10.3** | Guided voice clone UI (record + reading script + auto-clone) | 440 LOC clone window + 170 LOC AVAudioRecorder wrapper; `--quiet` machine contract | 2026-06-03 |
| **v1.10.4** | Clone diagnostic: WAV size log + Show WAV in Finder | binary + bundle bumped; cancel-row affordance | 2026-06-03 |
| **v1.10.5** | Daemon + CLI resolve sidecar via absolute path | `$AGENT_TTS_REPO_ROOT` → `/opt/homebrew/share/agent-tts` probe; voice routing finally correct from launchd cwd | 2026-06-03 |
| **v1.10.6** | XTTS quality knobs (temp/top_k/top_p/repetition_penalty) + longer reference window | re-clone bogdo → live playback validated; `AGENT_TTS_*` env overrides for A/B | 2026-06-04 |
| **v1.10.7** | Per-call Piper knobs (`--length-scale` / `--noise-scale` / `--noise-w`) + MCP | 8-field ENQUEUE with tune triplet; 3 new SQLite REAL columns; 11 MCP tools (added `synth_voice_test`) | 2026-06-04 |
| **v1.10.8** | Tech-report mode + max knob exposure (`--tech` / `--*-pause` / `--speaker-id` / `--profile tech`) + `voice_knob_search` MCP tool | 9-field ENQUEUE with extra quintuple; 5 new SQLite columns; 12 MCP tools; ~50-entry acronym/unit glossary | 2026-06-04 |

## KPI delivered

Every milestone was measured against **time-to-first-audio (TTFA)**.

| Target | Acceptance | Measured |
|---|---|---|
| Warm daemon say | < 300 ms | round-trip 0.1 ms + spawn 0.8 ms + playback ✅ |
| Piper warm synth (short) | < 1 s | **91 ms** ✅ (v0.7), 92.7 ms re-measured at v1.1 ✅ |
| Piper first-audio (long, v1.2) | < 200 ms | **41-52 ms** ✅ |
| Inter-chunk gap (v1.2) | < 10 ms | **0.02 ms median, 0.61 ms max** ✅ |
| Cold daemon boot | < 800 ms | pre-warm 280 ms + zaudio 79 ms + piper 373 ms = ~720 ms ✅ |
| Multi-piper boot (Pt only) | < 800 ms | pre-warm 255 ms + zaudio 54 ms + multi-piper 313 ms = ~622 ms ✅ |
| Lang detect per message | < 100 µs | informational, not captured this session |

Baselines: [`_qa/v0.1` … `_qa/v1.3`](https://github.com/biliboss/agent-tts/tree/main/_qa). Real audio-device dtruss not captured (SIP-on host); documented honestly in `_qa/v1.0-baseline.md`. v1.1+v1.2+v1.3 measurements live inline in the [Changelog](/agent-tts/changelog/).

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

## What's next

The whole v1.1 → v1.5 marketing slate shipped 2026-06-03. The next slate is unscheduled — see [What's next](/agent-tts/whats-next/) for the policy and how to push priority.

## Locked nots

- No embedded voice model in the binary (breaks the SSD goal).
- No Windows runtime guarantee in v1.3 (code paths exist, untested).
- No parallel TTS (overlap = bad UX).
- No Cocoa / AVSpeechSynthesizer until `say` proves insufficient.
- No YAML config before v1.1 (YAGNI).
- No cloud sync, no usage telemetry, no account, no quota. Ever.
