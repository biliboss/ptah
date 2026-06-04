---
title: Menubar UI
description: Native macOS menubar app for agent-tts — same UNIX-socket protocol as the CLI and the MCP server, third client on the wire.
---

## TL;DR

`AgentTTSMenubar` is a SwiftUI menubar app that gives the daemon a face. It speaks the same line-delimited TSV protocol the CLI and MCP server use — third client on `~/.cache/agent-tts/sock`, daemon unchanged. Live queue, click-to-skip, voice picker with cloned voices auto-discovered from disk. 321 KB binary, 911 Swift LOC, macOS 14+, Swift 5.9+.

Volume ducking and the Linux GTK4 equivalent are deferred to v1.10.1 — explicit honest scope in the [Changelog](/agent-tts/changelog/).

## Install

There is no signed `.app` yet — v1.10 ships the buildable Swift Package, not a brew cask. Build it from source:

```bash
cd ui/menubar
swift build -c release
.build/release/AgentTTSMenubar       # smoke run, unbundled
```

Wrap it into a `.app` bundle with the helper script:

```bash
./scripts/build-menubar.sh
open ui/menubar/build/AgentTTSMenubar.app
```

Then drag it into `Login Items` (System Settings → General → Login Items) so it starts on login alongside the daemon.

![AgentTTSMenubar status item — captured live from /Applications/AgentTTSMenubar.app on macOS 26.5](/agent-tts/screenshots/menubar-v1.10.1.png)

> v1.10.1 captures only the menubar strip. The popover screenshot (queue + voice picker open) lands in v1.10.2 alongside CoreAudio ducking + the signed brew cask.

## What's in the popover

- **Header** — title + refresh button (forces a queue re-poll).
- **Voice picker** — Luciana / Felipe / Faber / Amy plus any cloned voices discovered under `~/.cache/agent-tts/voices/<slug>/metadata.json` (same probe path `agent-tts --voice <slug>` uses). Selection persists to UserDefaults under `AgentTTSMenubar.selectedVoiceId`.
- **Floating-player toggle** (v1.10.2+) — "Show floating player while speaking" mirrors `AgentTTSMenubar.floatingPlayerEnabled` in UserDefaults. Default OFF on upgrade. When ON, the panel auto-shows during playback and auto-hides on idle (see below).
- **Queue list** — one row per item with a state dot (green = playing, grey = pending), the text preview, the engine + voice + rate, and the daemon's `id`. Polls every 750 ms while the popover is open, 0 polls while it's closed.
- **Footer** — Skip + Clear buttons (same semantics as `agent-tts skip` / `agent-tts clear`), last-poll round-trip readout in milliseconds, power button to quit.

## Clone your voice (v1.10.3+)

The popover gains a **Clone my voice…** row that opens a guided window for the v1.10.3 one-button voice-clone UX. No CLI, no manual WAV trimming, no `say -o` dance.

The window walks the user through five steps:

1. **Pick a slug** — single-line input validated against `[a-z0-9-]{1,32}` (same regex `src/voice.zig::validateSlug` enforces). Inline red hint when the slug is malformed.
2. **Read the script** — a hard-coded 30-90 s Pt-BR passage with varied prosody (declarative + interrogative + exclamative + lists + numbers + abbreviations + emotion). One sentence is highlighted at a time; an auto-advance timer moves the cursor forward every ~7 s so the user keeps pace.
3. **Tap Record** — first launch triggers `AVCaptureDevice.requestAccess(for: .audio)`, persisted by macOS. Denied → an actionable status string points the user at System Settings → Privacy & Security → Microphone.
4. **Watch the VU meter** — a live `peakLevel()` poll (50 ms tick) drives a green rectangle whose width tracks `averagePower(forChannel:0)`. Recording captures 22 050 Hz mono 16-bit s16le PCM — the exact shape `voice.zig::sniffWav` validates and the XTTS-v2 sidecar consumes natively.
5. **Save & Clone** — the WAV is staged to `~/.cache/agent-tts/voices/.tmp-<slug>.wav` and `agent-tts voice clone --sample <wav> --name <slug> --quiet` is spawned via `Process`. The subprocess's stdout + stderr stream into a log textbox so the XTTS sidecar's progress is visible. On exit code 0 the button becomes **Done** and the popover's voice picker reloads to surface the new slug.

The `--quiet` flag is a v1.10.3 addition (`src/voice.zig`): it suppresses the `[voice clone] …` progress chatter, redirects the sidecar's stdout to `/dev/null`, and emits exactly one parseable `OK\t<slug>\n` line on success. Errors still go to stderr so they show up in the menubar app's log textbox.

The bundle now ships an `NSMicrophoneUsageDescription` — required by macOS for any app that touches `AVAudioRecorder`. The string surfaces verbatim in the permission prompt.

![Clone window — captured live at the Recording state from /Applications/AgentTTSMenubar.app on macOS 26.5](/agent-tts/screenshots/v1.10.3-clone-window.png)

> Screenshot above is the live `_qa/v1.10.3-clone-window.png` captured at the "Recording…" state on macOS 26.5; the docs publish step will mirror it under `public/` on the next deploy.

## Floating player (v1.10.2+)

A compact 320×60 `NSPanel` that floats above other windows (`level = .floating`, `.canJoinAllSpaces`) and surfaces the currently playing item plus controls — so you can pause/resume/skip/replay without opening the popover. Lifecycle:

1. AppDelegate polls `agent-tts queue` every 750 ms regardless of popover state.
2. When a `state == "playing"` row appears AND the user toggled the widget on, the panel `orderFrontRegardless()`s.
3. When the queue empties or the playing row clears, the panel `orderOut()`s.
4. The panel persists its frame to `UserDefaults.AgentTTSMenubar.floatingFrame` (NSStringFromRect) so the user's preferred screen corner is sticky.

Controls:

- **Pause / Resume** (single button — SF Symbol switches `pause.fill` ↔ `play.fill`) → calls daemon `PAUSE` / `RESUME`. Disabled when no current item.
- **Skip** → daemon `SKIP`.
- **Replay** → daemon `REPLAY\t<currently-playing-id>` (re-enqueues the same utterance as a new pending row).

Enable from the popover toggle, or via shell:

```bash
defaults write io.github.biliboss.agent-tts.menubar AgentTTSMenubar.floatingPlayerEnabled -bool true
osascript -e 'tell application "AgentTTSMenubar" to quit'
open /Applications/AgentTTSMenubar.app
```

![Floating player overlay — captured live from /Applications/AgentTTSMenubar.app on macOS 26.5](/agent-tts/screenshots/menubar-v1.10.1.png)

> Screenshot above is the v1.10.1 baseline; the v1.10.2 floating-player render lives at `_qa/v1.10.2-floating-player-full.png` in the repo until the docs publish step grabs a clean crop.

## Protocol

The Swift client implements the v1.1 6-field `ENQUEUE` form and the matching `QUEUE` / `SKIP` / `CLEAR` ops, plus the v1.10.2 player ops `PAUSE` / `RESUME` / `REPLAY` / `HISTORY`. Same wire as [`src/ipc.zig`](https://github.com/biliboss/agent-tts/blob/main/src/ipc.zig):

```
→ ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>\n
← OK\t<id>\n

→ QUEUE\n
← ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n
← ...
← END\n

→ SKIP\n
← OK\t<id>\n        (id=0 ⇒ nothing was playing)

→ CLEAR\n
← OK\t<count>\n     (count of dropped pending items)

→ PAUSE\n           (v1.10.2)
← OK\t<id>\n        | ERR\tnothing playing\n

→ RESUME\n          (v1.10.2)
← OK\t<id>\n        | ERR\tnot paused\n

→ REPLAY\t<id>\n    (v1.10.2)
← OK\t<new_id>\n    | ERR\titem not found\n

→ HISTORY\t<limit>\n  (v1.10.2; limit clamped to 100, 0 = default 20)
← ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<finished_at>\t<text>\n
← ...
← END\n
```

The parser is permissive: it also accepts the v0.6 legacy `ITEM\t<id>\t<state>\t<voice>\t<rate>\t<text>` layout so a stale daemon doesn't break the UI.

## Architecture choices

| Decision | Rationale |
|---|---|
| Raw POSIX `Darwin.socket` instead of `Network.framework` NWConnection | NWConnection's callback model adds latency on the warm path the CLI publishes as 0.2-0.4 ms. The synchronous request/response shape is cleaner over plain BSD sockets |
| Swift Package, not Xcode project | Builds from the command line on any macOS with Command Line Tools — no Xcode dependency for CI, no `.xcodeproj` merge conflicts |
| `SocketProtocolCheck` standalone executable next to the XCTest target | XCTest is Xcode-only on macOS Command Line Tools, and Swift Testing's macro plugin is also Xcode-only. The XCTest file compiles under `#if canImport(XCTest)` so the package always builds; the executable provides a CI-portable smoke runner that exits non-zero on failure |
| `LSUIElement=true` (set both via Info.plist and `NSApp.setActivationPolicy(.accessory)`) | No dock icon, no app menu. Menubar-only is the whole point |
| Popover starts/stops polling on open/close | Saves IPC traffic — the daemon doesn't need a poll every 750 ms while the popover is closed |
| Click-to-skip only on the playing row in v1.10 | Daemon's `SKIP\n` targets the head of the queue. Per-id skip needs a daemon-side `SKIP\t<id>\n` extension. UI rows are clickable for forward-compat, so v1.10.1 plugs in without UI churn |

## Honest scope (deferred)

- **Volume ducking** — needs CoreAudio + entitlement + signing. v1.10.1
- **Linux GTK4 status icon** — different runtime, separate session. v1.10.1 or v1.11
- **Drag-to-reorder pending items** — needs a daemon-side `MOVE` op. v1.10.1
- **Per-id skip** — daemon extension, see above. v1.10.1
- **Signed `.app` + brew cask** — v1.10.1 alongside ducking

See also: [Architecture](/agent-tts/arquitetura/), [MCP server](/agent-tts/mcp/), [Changelog](/agent-tts/changelog/).
