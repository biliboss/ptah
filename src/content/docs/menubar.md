---
title: Menubar UI
description: Native macOS menubar app for ptah — same UNIX-socket protocol as the CLI and the MCP server, third client on the wire. Floating player + guided voice clone live since v1.10.2 / v1.10.3.
---

## TL;DR

`AgentTTSMenubar` is a SwiftUI menubar app that gives the daemon a face. It speaks the same line-delimited TSV protocol the CLI and MCP server use — third client on `~/.cache/ptah/sock`, daemon unchanged. Live queue, click-to-skip, voice picker with cloned voices auto-discovered from disk, floating overlay player (v1.10.2+), and a guided one-button voice-clone window (v1.10.3+). macOS 14+, Swift 5.9+.

Volume ducking and the Linux GTK4 equivalent are still on the wishlist — explicit honest scope at the bottom of this page.

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
cp -R ui/menubar/build/AgentTTSMenubar.app /Applications/
open /Applications/AgentTTSMenubar.app
```

`scripts/build-menubar.sh` bakes `AppIcon.icns` (16×16 → 512×512@2x, from `public/logos/ptah-logo.png` via `sips` + `iconutil`, baked into the bundle since v1.10.1) and stamps `NSMicrophoneUsageDescription` into the Info.plist so the v1.10.3 clone window can request mic access. Then drag the installed bundle into `Login Items` (System Settings → General → Login Items) so it starts on login alongside the daemon.

![AgentTTSMenubar status item — captured live from /Applications/AgentTTSMenubar.app on macOS 26.5](/ptah/screenshots/menubar-v1.10.1.png)

> v1.10.1 captures only the menubar strip. The popover screenshot (queue + voice picker open) lands in v1.10.2 alongside CoreAudio ducking + the signed brew cask.

## What's in the popover

- **Header** — title + refresh button (forces a queue re-poll).
- **Voice picker** — Luciana / Felipe / Faber / Amy plus any cloned voices discovered under `~/.cache/ptah/voices/<slug>/metadata.json` (same probe path `ptah --voice <slug>` uses since v1.4). Selection persists to UserDefaults under `AgentTTSMenubar.selectedVoiceId`. The picker only exposes engine + voice today — tech-profile knobs (`length_scale` / `noise_scale` / `noise_w` / `postfx`) stay env-only via `PTAH_*` or the MCP `say` arguments. See honest scope below.
- **Clone my voice…** row (v1.10.3+) — opens the guided clone window described in the next section.
- **Floating-player toggle** (v1.10.2+) — "Show floating player while speaking" mirrors `AgentTTSMenubar.floatingPlayerEnabled` in UserDefaults. Default OFF on upgrade. When ON, the panel auto-shows during playback and auto-hides on idle (see below).
- **Queue list** — one row per item with a state dot (green = playing, grey = pending), the text preview, the engine + voice + rate, and the daemon's `id`. Polls every 750 ms while the popover is open, 0 polls while it's closed.
- **Footer** — Skip + Clear buttons (same semantics as `ptah skip` / `ptah clear`), last-poll round-trip readout in milliseconds, power button to quit.

## Clone your voice (v1.10.3+)

The popover gains a **Clone my voice…** row that opens a guided window for the v1.10.3 one-button voice-clone UX. No CLI, no manual WAV trimming, no `say -o` dance.

The window walks the user through five steps:

1. **Pick a slug** — single-line input validated against `[a-z0-9-]{1,32}` (same regex `src/voice.zig::validateSlug` enforces). Inline red hint when the slug is malformed.
2. **Read the script** — a hard-coded 30-90 s Pt-BR passage with varied prosody (declarative + interrogative + exclamative + lists + numbers + abbreviations + emotion). One sentence is highlighted at a time; an auto-advance timer moves the cursor forward every ~7 s so the user keeps pace.
3. **Tap Record** — first launch triggers `AVCaptureDevice.requestAccess(for: .audio)`, persisted by macOS. Denied → an actionable status string points the user at System Settings → Privacy & Security → Microphone.
4. **Watch the VU meter** — a live `peakLevel()` poll (50 ms tick) drives a green rectangle whose width tracks `averagePower(forChannel:0)`. Recording captures 22 050 Hz mono 16-bit s16le PCM — the exact shape `voice.zig::sniffWav` validates and the XTTS-v2 sidecar consumes natively.
5. **Save & Clone** — the WAV is staged to `~/.cache/ptah/voices/.tmp-<slug>.wav` and `ptah voice clone --sample <wav> --name <slug> --quiet` is spawned via `Process`. The subprocess's stdout + stderr stream into a log textbox so the XTTS sidecar's progress is visible. On exit code 0 the button becomes **Done** and the popover's voice picker reloads to surface the new slug.

The `--quiet` flag is a v1.10.3 addition (`src/voice.zig`): it suppresses the `[voice clone] …` progress chatter, redirects the sidecar's stdout to `/dev/null`, and emits exactly one parseable `OK\t<slug>\n` line on success. Errors still go to stderr so they show up in the menubar app's log textbox.

The bundle ships an `NSMicrophoneUsageDescription` — required by macOS for any app that touches `AVAudioRecorder`. The string surfaces verbatim in the permission prompt.

### v1.10.4 — Staged WAV diagnostic + Show in Finder

The clone window logs the staged WAV path **and byte count** right before spawning the subprocess (`Staged WAV: /Users/.../voices/.tmp-<slug>.wav (1563906 bytes)`). The byte count is the diagnostic: **0 bytes ⇒ the recorder broke**, **non-zero ⇒ the sidecar broke**. The window also gains a **Show WAV in Finder** button that appears whenever `stagedURLForDebug` is set, so the user can `afplay` the staged recording without leaving the window. v1.10.4 fixed a user-facing failure where v1.10.3 surfaced `error: unknown flag '—quiet'` (em-dash rendered by the terminal font) because the installed binary lagged the bundle — the diagnostic now makes that class of failure obvious.

### v1.10.5 — Absolute path resolution for `voice_synth.py`

The daemon's clone-time call to the Python sidecar now resolves `voice_synth.py` via the binary's absolute install path instead of `argv[0]`-relative lookup, so the menubar's spawned `ptah voice clone --quiet` finds the sidecar even when the menubar app launches the daemon from a different working directory than the CLI. Fully transparent to the menubar code; the user-visible effect is "Save & Clone works on first launch after install" instead of needing a manual `ptah daemon restart` first.

![Clone window — captured live at the Recording state from /Applications/AgentTTSMenubar.app on macOS 26.5](/ptah/screenshots/v1.10.3-clone-window.png)

> Screenshot above is the live `_qa/v1.10.3-clone-window.png` captured at the "Recording…" state on macOS 26.5; the docs publish step will mirror it under `public/` on the next deploy.

## Floating player (v1.10.2+)

A compact 320×60 `NSPanel` that floats above other windows (`level = .floating`, `.canJoinAllSpaces`, `.hudWindow` style) and surfaces the currently playing item plus controls — so you can pause/resume/skip/replay without opening the popover. Lifecycle:

1. AppDelegate polls `ptah queue` every 750 ms regardless of popover state.
2. When a `state == "playing"` row appears AND the user toggled the widget on, the panel `orderFrontRegardless()`s.
3. When the queue empties or the playing row clears, the panel `orderOut()`s.
4. The panel persists its frame to `UserDefaults.AgentTTSMenubar.floatingFrame` (NSStringFromRect) so the user's preferred screen corner is sticky.

Controls:

- **Pause / Resume — single button** (SF Symbol switches `pause.fill` ↔ `play.fill` based on `current_playing_id` + paused state) → calls daemon `PAUSE` / `RESUME`. Disabled when no current item.
- **Skip** → daemon `SKIP`.
- **Replay** → daemon `REPLAY\t<currently-playing-id>` (re-enqueues the same utterance as a new pending row).

Enable from the popover toggle, or via shell:

```bash
defaults write io.github.biliboss.ptah.menubar AgentTTSMenubar.floatingPlayerEnabled -bool true
osascript -e 'tell application "AgentTTSMenubar" to quit'
open /Applications/AgentTTSMenubar.app
```

![Floating player overlay — captured live from /Applications/AgentTTSMenubar.app on macOS 26.5](/ptah/screenshots/menubar-v1.10.1.png)

> Screenshot above is the v1.10.1 baseline; the v1.10.2 floating-player render lives at `_qa/v1.10.2-floating-player-full.png` in the repo until the docs publish step grabs a clean crop.

## Protocol

The Swift client implements the v1.1 6-field `ENQUEUE` form and the matching `QUEUE` / `SKIP` / `CLEAR` ops, plus the v1.10.2 player ops `PAUSE` / `RESUME` / `REPLAY` / `HISTORY`. Same wire as [`src/ipc.zig`](https://github.com/biliboss/ptah/blob/main/src/ipc.zig):

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

## Honest scope (still deferred at v1.10.13)

- **Volume ducking** — needs CoreAudio + entitlement + signing. Wishlist; no v1.11 date.
- **Linux GTK4 status icon** — different runtime, separate session. Wishlist.
- **Drag-to-reorder pending items** — needs a daemon-side `MOVE` op.
- **Per-id skip** — daemon extension, see above (`SKIP\t<id>\n`).
- **Signed `.app` + brew cask** — ad-hoc codesign (`-` identity) today; brew cask + notarization pending.
- **Tech-profile knobs in the picker** — `length_scale` / `noise_scale` / `noise_w` / `postfx` are env-only or per-MCP-call today. The picker surfaces engine + voice only. The MCP `tech_profile_search` tool is the production discovery loop; see [MCP server → tech_profile_search](/ptah/mcp/#v1109--v11010--tech_profile_search-42-matrix).

See also: [Architecture](/ptah/arquitetura/), [MCP server](/ptah/mcp/), [Changelog](/ptah/changelog/).
