---
title: Architecture
description: Single Zig binary, CLI + daemon over UNIX socket, SQLite WAL queue, two interchangeable TTS engines (libpiper + macOS say).
---

## TL;DR

Single Zig 0.16 binary. Three modes share one executable: client (default), daemon, and MCP server. The client sends a message over a UNIX socket. The daemon stores it in a SQLite WAL queue and drains serially. Each item is routed to one of two engines: **libpiper** (neural, default) or **macOS `say`** (fallback). Audio plays through **zaudio** (PCM streaming) for piper or directly through `say` for the system voice. Auto-start is handled by **launchd**. The MCP mode (v1.5+) bridges stdio JSON-RPC to the same UNIX socket so agent runners like Claude Code, Cursor, and Cline call the daemon without a shell.

Every component exists to cut **time-to-first-audio (TTFA)**.

## Diagram

```
┌─────────────┐    UNIX socket    ┌────────────────────┐
│  agent-tts  │ ───ENQUEUE──────▶ │       daemon       │
│  (client)   │ ◀── OK + id ────  │  - accept loop     │
└─────────────┘                   │  - SQLite WAL      │
                                  │  - worker thread   │
                                  └────────┬───────────┘
                                           │ route by item.engine
                              ┌────────────┴────────────┐
                              ▼                         ▼
                       ┌─────────────┐          ┌───────────────┐
                       │  /usr/bin/  │          │   libpiper    │
                       │    say      │          │  (PiperEngine)│
                       │  -v Luciana │          │  → s16le PCM  │
                       └─────────────┘          └──────┬────────┘
                                                       │
                                                       ▼
                                                ┌──────────────┐
                                                │    zaudio    │
                                                │  (miniaudio) │
                                                └──────────────┘
```

Filesystem layout:

```
~/.cache/agent-tts/
  queue.db          SQLite WAL (items + state machine)
  sock              UNIX stream socket
  voices/           Piper ONNX models (downloaded once)
  daemon.out.log    launchd stdout
  daemon.err.log    launchd stderr

~/Library/LaunchAgents/
  io.github.biliboss.agent-tts.plist
```

## Components

### Language: Zig 0.16

- Native arm64 / x86_64 binary, no runtime, no GC
- Predictable latency, no stop-the-world
- Direct FFI to `libpiper`, `libsqlite3`, and `miniaudio` via `@cImport`
- ReleaseFast with libpiper linked: **~975 KB**

Version pinned in `build.zig.zon` — Zig still breaks between minor releases.

### CLI + daemon + MCP share the binary

Cuts install surface. `agent-tts` without args = client. `agent-tts daemon` = server. `agent-tts mcp` = stdio JSON-RPC bridge for MCP clients (v1.5+). Dispatch by `argv[1]`.

The client does NOT fork the daemon. The daemon survives because of launchd (`agent-tts daemon install`), so the warm-path round-trip stays under a millisecond.

### IPC: UNIX socket

Path: `~/.cache/agent-tts/sock`. Faster than TCP loopback (no checksum, no TCP stack). Line-delimited TSV protocol:

```
→ ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n
← OK\t<id>\n
```

Other ops:
- `QUEUE\n` → daemon emits `ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n` lines followed by `END\n`
- `SKIP\n` → SIGTERMs the current `say` PID (or signals piper playback to stop) → `OK\t<id>\n`
- `CLEAR\n` → marks every pending item as `skipped` → `OK\t<count>\n`

Cleanup: the daemon registers SIGTERM/SIGINT and unlinks the socket on exit. On startup it checks if the PID in `daemon.pid` is still alive before assuming an orphan socket.

### Queue: SQLite WAL

`~/.cache/agent-tts/queue.db`. Survives daemon crash, reboot, and SKIP. WAL mode lets the worker drain without blocking `agent-tts queue` reads.

Schema:

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  voice TEXT,
  rate INTEGER,
  engine TEXT NOT NULL DEFAULT 'say',
  state TEXT NOT NULL DEFAULT 'pending',
  enqueued_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER
);
```

Worker = a single thread loop. Never two synth/playback in parallel — overlap kills UX. Mutual exclusion is implicit from the single-consumer queue. Inside one piper item, v1.2 splits work across two cooperating threads (synth → audio) so long inputs don't pay full-input synth before first sample. The single-item invariant still holds: only one queue entry is ever in flight.

Crash recovery on daemon boot: `UPDATE items SET state='pending' WHERE state='playing'` re-promotes orphan items from the previous run.

### Engine routing

Selected per item via the `engine` column. The worker picks the matching path:

| `item.engine` | Path |
|---------------|------|
| `say` | `tts.spawnSay(voice, rate, preprocessed_text)` → blocks on `wait()` |
| `piper` (1 chunk) | `MultiPiperEngine.synthLang(text, route)` → `AudioPlayer.streamS16leAppend(samples, 22050)` (v0.7 fast path) |
| `piper` (>1 chunk) | v1.2 pipeline: synth thread + audio thread + 2-slot bounded ring; per-chunk lang via `detect.detect` |
| `cloned` (v1.4) | spawn `scripts/voice_synth.py` → drain s16le PCM on stdout → `AudioPlayer.streamS16le(samples, 22050)` |

If `--engine piper` arrives but the engine is not loaded (binary built without `-Dwith-piper=true`, or `AGENT_TTS_PIPER=1` was not set), the worker logs a warning and falls back to `say`. For `cloned`, missing embedding OR sidecar failure falls back to piper Faber when available, else `say` Luciana.

### Streaming pipeline (v1.2)

For multi-sentence piper items, `runPiper` calls `preproc.chunkSentences` to split on `. ! ? \n` (abbreviation-aware: `Sr. Dr. Sra. Av. cf. etc. vs.` don't terminate). When chunk count is 1, the worker takes the v0.7 fast lane. When >1, it forks:

- **Synth thread** — for each chunk, allocates a per-chunk arena off `std.heap.smp_allocator` (lock-free fast path), calls `engine.synthToSamples`, pushes the samples + arena into the ring. Blocks on a 2 ms nanosleep when the ring is full.
- **Audio thread (= worker loop)** — pops from the ring, calls `AudioPlayer.streamS16leAppend`, deinits the chunk's arena. Blocks on 2 ms nanosleep when the ring is empty and synth hasn't closed it.
- **Ring** — 2-slot SPSC, atomic `head` / `tail`. No `std.Thread.Mutex` (Zig 0.16 removed it; same `nanosleep` idiom already used in `audio.zig`).
- **SKIP** — sets a `skip` flag the synth thread checks on every iteration; audio thread drains the ring and breaks.

Result on a 490-word Pt-BR monologue: first-audio drops from ~3 s (v0.7 serial) to **~50 ms** (v1.2 streaming). Inter-chunk gap median is 0.02 ms with back-to-back `AudioBuffer + Sound` plays — well below one device period, so a custom `decoderReadProc` ring isn't needed today (deferred to v1.2.1 if a workload proves the gap audible).

### Incremental chunker (v1.7)

The v1.2 pipeline assumes the full text is available before chunking. v1.7 adds an `IncrementalChunker` state machine in `preproc.zig` for the streaming-input case (`agent-tts stream` over stdin and `say_stream` MCP tool):

- **`buffer: ArrayList(u8)`** — bytes received but not yet emitted. The chunker compacts the buffer (drops the consumed prefix) after every emission.
- **`scan_idx`** — cursor into `buffer` for the next byte to inspect. Reset to 0 on compaction so each byte is touched O(1) amortized across all `feed` calls.
- **`feed(arena, bytes) → []Chunk`** — appends `bytes`, walks `scan_idx` forward, emits every terminator-bounded sentence. Chunks are dup'd into `arena` (the internal buffer may reallocate on the next feed, so handing out internal slices would dangle). Abbreviation guard mirrors batch (`Sr./Dr./Sra./Dra./Av./cf./etc./vs.` do not split).
- **`flush(arena)`** — emits the buffered remainder as a single chunk at EOF / `final=true`. Resets state for reuse.

Emission policy is **eager**: a terminator run that touches end-of-buffer emits the chunk anyway. The cost is that an ellipsis split across two reads ("hmm.." + ".") emits as two chunks ("hmm.." + ".") instead of one ("hmm..."). For the voice UX, low-latency emission wins — the alternative (buffering across feeds, holding the chunk until a non-terminator confirms run closure) defeats the streaming goal whenever the agent stops typing mid-ellipsis.

The CLI path (`stream.zig`) reads stdin in 4 KB blocks via `readSliceShort` and feeds each block. The MCP path (`mcp.zig` → `callSayStream`) holds a `StringHashMapUnmanaged(StreamSession)` keyed by caller-chosen `stream_id`; each session owns its own gpa-backed `ArenaAllocator` so chunker state survives across per-request arenas.

### libpiper FFI

Vendored from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) at tag `v1.4.2`. Built once via `scripts/build-libpiper.sh`. Links against `libpiper.dylib` + `libonnxruntime.1.22.0.dylib` (resolved via `@rpath`).

`PiperEngine` is a Zig struct owning the C handle. Init loads the ONNX voice model (~400 ms cold), exposes `synthToSamples(text) → []i16`. Lives in daemon-scoped storage so the cold cost is paid once.

License: GPL-3.0-or-later. Built into the binary only when `-Dwith-piper=true`; without it, the binary is MIT/Apache.

### Audio: zaudio (miniaudio)

Vendored from [zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio). Linked against CoreAudio / AudioUnit / AudioToolbox frameworks on macOS. The daemon owns one `zaudio.Engine` instance.

`AudioPlayer.streamS16le(samples, 22050)` creates an `AudioBuffer` data source pinned to the source rate (22050 Hz for Faber). Without the explicit sample rate, miniaudio upsamples to the device rate (48000 Hz) and pitch shifts ~2.18× higher — a fix shipped in v1.0. `streamS16leAppend` is the v1.2 alias used by the streaming worker; today it shares `streamS16le`'s body because measured inter-chunk gaps stay below one device period.

### MCP server (v1.5+)

`src/mcp.zig` adds a third entry point: `agent-tts mcp` runs a stdio JSON-RPC 2.0 loop. Newline-delimited JSON (NOT LSP-style `Content-Length` framing — that is the MCP convention for stdio transport). Methods landed in v1.5:

- `initialize` → returns `protocolVersion: 2024-11-05`, `capabilities.tools.listChanged=false`, `serverInfo`
- `notifications/initialized` → acked, no response
- `tools/list` → 5 tool descriptors
- `tools/call` → dispatches by name; result is a `content: [{ type: "text", text: "..." }]` block + `isError: bool`

The 5 tools shim the existing UNIX socket protocol via `client.zig` helpers — `enqueueLine`, `queueLines`, `skipOp`, `clearOp`:

| Tool | Maps to | Returns |
|------|---------|---------|
| `say` | `ENQUEUE` | `{ id }` |
| `queue` | `QUEUE` | `{ items: [...] }` |
| `skip` | `SKIP` | `{ skipped_id }` |
| `clear` | `CLEAR` | `{ cleared_count }` |
| `voices` | local file scan | `{ voices: [...] }` (hardcoded `say` + `~/.cache/agent-tts/voices/*.onnx` for piper) |

No new wire protocol, no daemon changes. The MCP server is a 500-line shim over the same socket the CLI uses. Errors from the daemon path become `isError: true` MCP responses with a human-readable `text` block; the JSON-RPC envelope itself only fails on parse errors (`-32700`) or unknown methods (`-32601`).

Honest scope: `prompts/*`, `resources/*`, `sampling/*`, `logging/*`, and server-initiated progress notifications are not implemented. A voice agent needs tools and only tools — the other primitives land when somebody asks.

Install snippet (also see `scripts/install-mcp.sh`):

```json
{
  "mcpServers": {
    "agent-tts": {
      "command": "/opt/homebrew/bin/agent-tts",
      "args": ["mcp"]
    }
  }
}
```

### Python sidecar (v1.4 — cloned engine only)

`agent-tts voice clone --sample <wav> --name <slug>` spawns `scripts/voice_clone.py` via `std.process.Child` to extract the XTTS-v2 speaker conditioning latents from the reference WAV. Synthesis at request time spawns `scripts/voice_synth.py`, which reads text on stdin and writes raw s16le mono 22050Hz PCM to stdout. The daemon drains stdout into a buffer + feeds the same `AudioPlayer.streamS16le` path Faber uses.

Spawn convention: `uv run --with TTS <script>` when `uv` is on PATH, else plain `python3 <script>` (assumes the venv created by `scripts/setup-voice-clone.sh` is activated). The script files at `scripts/voice_clone.py` + `scripts/voice_synth.py` carry SPDX MIT/Apache headers; Coqui TTS itself is MPL-2.0 and runs out-of-process — no MPL code is linked into the Zig binary.

Fallback chain (handled in `daemon.zig::fallbackCloned`): missing embedding OR sidecar exit ≠ 0 → piper Faber (when loaded) → `say` Luciana.

The "only Zig" lifecycle constraint is intentionally relaxed for this engine only. Faber + say still work without Python. See `docs/motor.md` "Cloned voices (v1.4)" for the licensing + UX rationale.

### Drive: `say` / `espeak-ng` / System.Speech

System engine spawn per platform — selected at comptime via `platform.zig` (see [Platform abstraction](#platform-abstraction-v13) below):

- **macOS**: `/usr/bin/say -v "Luciana (Premium)" -r 330`. Pre-warm at daemon boot loads the voice into the Neural Engine; without it, the first call pays an extra 200-400 ms.
- **Linux**: `espeak-ng -v pt-br -s <rate> <text>`. Lowest-common-denominator Pt-BR voice. No pre-warm (no equivalent to the ANE cache). Quality is below macOS Luciana — Piper Faber is the recommended Linux default.
- **Windows**: `powershell -Command "Add-Type System.Speech; $s.Speak(...)"`. Best-effort; runtime untested in v1.3.

### Pt-BR preprocessor (v0.5)

Runs before each engine sees the text. Three transforms, single pass each, allocated in a per-utterance arena:

| Input | Output |
|-------|--------|
| `,` | `, [[slnc 150]]` |
| `.` `!` `?` | `<punct> [[slnc 400]]` |
| `\n` | `[[slnc 600]]` |
| `Sr.` | `Senhor` |
| `cf.` | `conforme` |
| `123` | `cento e vinte e três` (cardinals 0..9999) |
| `R$` | `reais` |

`[[slnc N]]` directives are literal `say` commands; piper ignores them.

Total wall time: 2-5 µs per message. No TTFA risk.

### launchd auto-start

`agent-tts daemon install` writes `~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist` and bootstraps it into the `gui/<uid>` domain. KeepAlive uses the `SuccessfulExit=false` dict form — a clean `bootout` actually stays out.

Plist write is atomic (`createFileAtomic` + `replace`). The `HOME` env var is injected explicitly because launchd does not inherit it pre-login.

### Platform abstraction (v1.3)

Three small surfaces, one comptime dispatcher, zero runtime branches in the hot path.

`src/platform.zig` exports `Platform { macos, linux, windows }` and `current()`, a comptime function that resolves to a single tag via `builtin.target.os.tag`. Unknown OS tags are a `@compileError` — better to fail the build than to ship a binary that does the wrong thing silently. Callers `switch (comptime platform.current())` so dead branches drop out of the binary on the host target.

`src/tts.zig` uses the dispatcher to pick the system TTS argv per platform:

| Platform | Spawn |
|---|---|
| macOS | `/usr/bin/say -v <voice> -r <rate> <text>` |
| Linux | `espeak-ng -v pt-br -s <rate> <text>` (Pt-BR voice mapping is unit-tested) |
| Windows | `powershell -NoProfile -Command "Add-Type System.Speech; $s.Speak('...')"` (best-effort) |

Pre-warm (the empty `say` utterance that loads Luciana into the Neural Engine) becomes a no-op on Linux/Windows — `espeak-ng` and `System.Speech` have no equivalent warm cache.

`src/systemd.zig` parallels `launchd.zig`. Same surface: `install`, `uninstall`, `status`. Writes `$XDG_CONFIG_HOME/systemd/user/agent-tts.service` (falls back to `~/.config/systemd/user/`), drives `systemctl --user daemon-reload && enable --now`. Atomic write via `createFileAtomic` + `replace` like the plist. `Restart=on-failure` mirrors the launchd `KeepAlive { SuccessfulExit = false }` contract: clean exit stays down, crash recovers. Output goes to journald — `journalctl --user -u agent-tts` is the canonical Linux debug path.

`build.zig configureExe()` switches the audio backend per target:

| Target | miniaudio defines | System libs |
|---|---|---|
| macOS | `MA_NO_RUNTIME_LINKING` + everything but CoreAudio off | CoreAudio + CoreFoundation + AudioUnit + AudioToolbox frameworks |
| Linux | `MA_NO_COREAUDIO` (ALSA + PulseAudio runtime-linked) | `libasound` static + `libpulse` via miniaudio's `dlopen` |
| Windows | `MA_NO_RUNTIME_LINKING` + everything but WASAPI + winmm off | `winmm` + `ole32` |

`main.zig`'s `daemon install|uninstall|status` is a single comptime switch: macOS → `launchd.*`, Linux → `systemd.*`, Windows → print error and exit 2. Same CLI surface, different machinery underneath.

## Code layout

```
src/
  main.zig         # entry, argv routing, ttfa-bench + piper-test + voice + mcp subcommands
  platform.zig     # comptime OS dispatcher (macos / linux / windows)
  client.zig       # enqueue, queue, skip, clear + pure helpers reused by mcp.zig
  daemon.zig       # accept loop, worker, engine routing
  queue.zig        # SQLite WAL wrapper, schema migration
  ipc.zig          # line protocol, sanitize, Engine + Lang enums
  tts.zig          # spawn `say` (macOS) / `espeak-ng` (Linux) / powershell (Windows)
  piper.zig        # libpiper FFI (GPL-3.0-or-later) + MultiPiperEngine (v1.1)
  audio.zig        # zaudio.Engine wrapper
  preproc.zig      # Pt-BR cadence + abbreviations + cardinals + chunkSentences (v1.2)
  detect.zig       # v1.1 — Pt/En stopword-heuristic language detector
  launchd.zig      # LaunchAgent install / uninstall / status (macOS)
  systemd.zig      # systemd user unit install / uninstall / status (Linux)
  voice.zig        # v1.4 — `voice clone` / `voice list` subcommands
  mcp.zig          # v1.5 — MCP server (stdio JSON-RPC 2.0)

scripts/
  voice_clone.py        # v1.4 — XTTS-v2 speaker latent extraction
  voice_synth.py        # v1.4 — XTTS-v2 PCM synthesis to stdout
  setup-voice-clone.sh  # v1.4 — uv venv bootstrap
  install-mcp.sh        # v1.5 — Claude Code MCP config installer
  fetch-voice-en.sh     # v1.1 — Amy En voice
```

Flat. No subdir until it hurts.

## Locked gotchas

- `say -v Luciana` silently fails if the voice is not installed. The daemon validates with `say -v '?'` at boot and logs a warning.
- Orphan socket after SIGKILL — startup checks the PID file before reusing it.
- SQLite without WAL blocks `queue` during `playing`. Always WAL.
- `AudioBuffer.Config.sample_rate` must be set explicitly; the default upsamples to engine rate and shifts pitch.
- espeak-ng (under libpiper) caps phoneme source paths at 160 bytes. Build libpiper in a short path (`/tmp/agent-tts-piper-build`); the vendor script does this for you.
- `char32_t` in `piper.h` fails Zig's `translate-c`. Shim with `@cDefine("char32_t", "uint32_t")` before `@cInclude`.
