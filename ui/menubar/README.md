# AgentTTSMenubar

macOS menubar UI for the ptah daemon. Third client on the same UNIX-socket TSV protocol that powers the CLI (`src/client.zig`) and the MCP shim (`src/mcp.zig`).

## What it does

- Status item icon (speaker glyph) in the menubar.
- Popover (320×420) with:
  - Live queue showing `pending` / `playing` rows. Polls every 750 ms while open.
  - Voice picker — Luciana, Felipe, Faber, Amy, plus any cloned voices under `~/.cache/ptah/voices/<slug>/metadata.json`. Selection persists to UserDefaults.
  - Skip + Clear buttons backed by `SKIP\n` / `CLEAR\n`.
  - Round-trip latency readout (last poll, milliseconds).
- No daemon modifications. The Swift app is a thin client.

## What's deferred (honest scope)

- **Volume ducking** while speaking — needs CoreAudio's `AudioObjectGetPropertyData` + tap registration, plus an entitlement. Deferred to **v1.10.1**.
- **Drag-to-reorder pending items** — needs a daemon-side `MOVE` op. Deferred.
- **Per-id skip** — daemon `SKIP` always targets the head. UI rows are clickable but only act on the playing row today. Deferred to v1.10.1.
- **Linux GTK4 equivalent** — deferred.

## Build

Requires Swift 5.9+ and macOS 14+.

```bash
cd ui/menubar
swift build -c release
```

Run unbundled (handy for smoke during dev):

```bash
.build/release/AgentTTSMenubar
```

To build a redistributable `.app` bundle:

```bash
../../scripts/build-menubar.sh
```

The script writes `build/AgentTTSMenubar.app/` containing the binary plus a minimal `Info.plist` with `LSUIElement=true` so no dock icon shows up.

## Test

```bash
cd ui/menubar
swift test
```

The test target covers the wire-protocol parser (`SocketClient.sanitize`, `SocketClient.parseOk`, `SocketClient.parseItem`) and the voice catalogue. Socket round-trips against a live daemon are exercised manually — see `_qa/v1.10-baseline.md` once captured.

## Protocol

Same protocol as the CLI — see [`src/ipc.zig`](../../src/ipc.zig) for the canonical spec.

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
```

The Swift parser is permissive: it accepts the v0.6 legacy layout (`ITEM\t<id>\t<state>\t<voice>\t<rate>\t<text>`, no engine field) so a stale daemon doesn't break the UI.

## Install

For now, the menubar app ships unbundled. After `swift build -c release` you can wire it into Login Items manually:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/path/to/.build/release/AgentTTSMenubar", hidden:false}'
```

A signed `.app` + brew cask lands in v1.10.1 alongside ducking.
