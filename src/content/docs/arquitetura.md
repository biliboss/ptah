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
  daemon.log        v1.10.13+ structured log sink (rotates at 10 MiB)
  daemon.log.1..3   rotated backups

~/Library/LaunchAgents/
  io.github.biliboss.agent-tts.plist
```

## Logging & observability (v1.10.13+)

The daemon uses `std.log.scoped(...)` instead of ad-hoc `std.debug.print`. Every call site picks a scope (`daemon`, `worker`, `audio`, `postfx`, `mcp`, …) and a level (`err` / `warn` / `info` / `debug`). The custom `logFn` (in `src/log.zig`) writes each line to BOTH stderr (launchd captures it in `daemon.err.log` — backwards-compatible) AND a rotating file at `~/.cache/agent-tts/daemon.log`.

Line format:

```
2026-06-04T13:03:46.972Z [info] [worker] piper id=224 streaming chunks=4 first_audio=343.6ms total=6150.7ms samples=104448
```

- **Timestamp** — ISO 8601 UTC with millisecond resolution (via `libc clock_gettime` + `gmtime_r`).
- **Level** — `info` / `warning` / `error` / `debug`.
- **Scope** — module identity. The CLI subcommand handlers (`client`, `voice`, `stream`, `launchd`) keep `std.debug.print` because their output is for the calling shell, not the daemon log.

Operator knobs (read once on first log call, cached for daemon lifetime — restart to apply):

| Env var | Default | Purpose |
| --- | --- | --- |
| `AGENT_TTS_LOG_PATH` | `~/.cache/agent-tts/daemon.log` | File sink path |
| `AGENT_TTS_LOG_LEVEL` | `info` | Drops messages below this level. Use `debug` for verbose chain dumps. |
| `AGENT_TTS_LOG_SCOPES` | (empty = all) | Comma-separated allow-list, e.g. `worker,postfx`. Up to 16 entries. |
| `AGENT_TTS_LOG_MAX_BYTES` | `10485760` (10 MiB) | Rotation threshold. When the active file exceeds this, `daemon.log → .1`, `.1 → .2`, `.2 → .3`, oldest dropped. |
| `AGENT_TTS_POSTFX_TIMEOUT_MS` | `5000` | Postfx ffmpeg watchdog deadline. On expiry the subprocess is `SIGTERM`'d (then `SIGKILL` after a 1 s grace) and the worker falls through to dry PCM. |

The `worker` thread also emits a `debug`-level heartbeat (`worker heartbeat queue=N current_playing_id=X`) every 10 s. Heartbeats are silent at default `info` level; set `AGENT_TTS_LOG_LEVEL=debug` to see them.

**Worker resilience (v1.10.13).** `workerLoop` now wraps `runOne` with `defer res.queue.finishPlaying(io, item.id)`. Every `runOne` path is supposed to call `finishPlaying` itself, but the v1.10.12 audit found error escapes (OutOfMemory on SSML cadence prep, panics inside the SSML walker, postfx returns to a closed pipe) that could leave the row stuck in `playing`. The `defer` is idempotent over `state='playing'`, so the well-behaved paths that already called it are unaffected — the defer only fires when the explicit call was skipped due to an error escape. Combined with the postfx watchdog, a single bad item can no longer wedge the queue.

The synth side does NOT yet have a similar watchdog. The v1.10.13 spec asked for a 20 s soft-warn + 60 s hard-fail around piper inference, but libpiper exposes no `piper_cancel()` C ABI — a hard fail would leak the synth thread. The diagnosed v1.10.12 stall was postfx, not synth, so the defer + watchdog combo above closes the actual hole. An `AGENT_TTS_SYNTH_TIMEOUT_MS` knob is pencilled in for v1.10.14+ if a real synth hang ever shows up in production.

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

### Third client: SwiftUI menubar app (v1.10+)

`ui/menubar/AgentTTSMenubar.app` is a Swift Package outside the Zig binary that talks the same UNIX-socket TSV protocol. NSStatusItem hosts a 320×420 SwiftUI popover with the live queue, Skip + Clear buttons, and a voice picker that discovers cloned voices under `~/.cache/agent-tts/voices/<slug>/metadata.json`. The daemon is unchanged — the menubar app is a third client on the wire, alongside the CLI and the MCP shim. See [Menubar UI](/agent-tts/menubar/).

**v1.10.2 — floating player overlay.** AppDelegate runs a 750 ms `Timer` that polls `QUEUE` regardless of popover state. When a `state=="playing"` row appears AND the user toggled the floating widget on (`AgentTTSMenubar.floatingPlayerEnabled` in UserDefaults), an always-on-top `NSPanel` (`level = .floating`, `.hudWindow` style, `.canJoinAllSpaces`) shows the current item plus pause / resume / skip / replay buttons. The polling cadence matches the popover's so daemon load is constant; the toggle defaults OFF so v1.10.1 upgrades don't surface a new window unexpectedly.

### Player ops (v1.10.2+): PAUSE / RESUME / REPLAY / HISTORY

The daemon's worker thread publishes the active row id into `Resources.current_playing_id` (atomic `u64`) when it pops; clears it when runOne returns. PAUSE/RESUME accept-thread handlers read that cell, call `AudioPlayer.pause()` / `.resume_play()` (which drive zaudio `sound.stop()`/`sound.start()`), and ack `OK\t<id>`. The streamS16le wait loop in `audio.zig` now stays parked (20 ms nanosleep) while the `paused` atomic is set, so the loop doesn't exit on `isAtEnd` mid-pause.

REPLAY does a `SELECT … WHERE id=?` followed by `INSERT … VALUES (text,voice,rate,'pending',now,engine,ssml)` under `q.mu` — the schema has persisted completed rows since v0.3 WAL, so any past id is replayable. HISTORY does a `SELECT … ORDER BY id DESC LIMIT ?` and adds a `finished_at` column to the ITEM wire shape (8 columns instead of QUEUE's 7), keeping QUEUE backward-compatible. Limit clamped to 100 at parse time for WRITE_BUF hygiene.

### IPC: UNIX socket

Path: `~/.cache/agent-tts/sock`. Faster than TCP loopback (no checksum, no TCP stack). Line-delimited TSV protocol.

Current ENQUEUE shape (v1.10.10 — **10 fields**):

```
→ ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<ssml>\t<tune>\t<extra>\t<postfx>\t<text>\n
← OK\t<id>\n
```

- `<engine>` — `say` / `piper` / `cloned` (Engine enum tag).
- `<lang>` — `auto` / `pt` / `en` (Lang enum tag); defaults to `auto`.
- `<voice>` — engine-specific. Empty string accepted (daemon picks default).
- `<rate>` — integer wpm. `0` = engine default.
- `<ssml>` — `0` / `1`. When `1`, daemon routes through `src/ssml.zig` before synth.
- `<tune>` — `<length>:<noise>:<noise_w>` triplet (v1.10.7+). Each component is a float literal or `-` for "unset". Empty string = all unset.
- `<extra>` — `<tech>:<comma>:<sentence>:<newline>:<speaker>` quintuple (v1.10.8+). Empty string = all defaults.
- `<postfx>` — `off` / `clean` / `tech` / `broadcast` (v1.10.10+). Slot is omitted entirely when `.off`, collapsing to the 9-field shape.
- `<text>` — final field; survives raw tabs/newlines because there's no terminator after it before `\n`.

**Backward-compat parse rule** (`src/ipc.zig::parseRequest`): the daemon peeks each field by content, not by position, walking up through 4-/5-/6-/7-/8-/9-/10-field layouts. The peek table:

| Decision point | Token shape |
|---|---|
| Field 1 | matches `Engine.fromStr` → v0.7+; else → v0.6 4-field (token is voice) |
| Field 2 | matches `Lang.fromStr` → v1.1+; else → v0.7 5-field |
| Field after `<rate>` | exactly `0`/`1` → v1.8+ ssml flag; else → v1.1 6-field text |
| Field after `<ssml>` | empty OR contains `:` → v1.10.7+ tune; else → v1.8 7-field text |
| Field after `<tune>` | empty OR `:`-with-≥4-colons → v1.10.8+ extra; else → v1.10.7 8-field text |
| Field after `<extra>` | matches `Postfx.fromStr` (`off`/`clean`/`tech`/`broadcast`) → v1.10.10 10-field; else → v1.10.8 9-field text |

This is why a stale v0.6 client still talks to a v1.10.13 daemon, and why v1.10.13 stays at 10 fields (not 11) even though v1.10.12 added the SSML cadence pass — cadence is gated on the existing `<extra>` tech flag rather than a new wire slot, so no field grew.

Other ops:
- `QUEUE\n` → daemon emits `ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\n` lines followed by `END\n`
- `HISTORY\t<limit>\n` (v1.10.2+) → `ITEM\t<id>\t<state>\t<engine>\t<voice>\t<rate>\t<text>\t<finished_at>\n` × N + `END\n`
- `PAUSE\n` / `RESUME\n` (v1.10.2+) → drive `AudioPlayer.pause()` / `.resume_play()` on the current `Resources.current_playing_id`; `OK\t<id>\n`
- `REPLAY\t<id>\n` (v1.10.2+) → re-enqueues row `<id>` with its full knob bundle (engine/voice/rate/ssml/tune/extra/postfx); `OK\t<new_id>\n`
- `SKIP\n` → SIGTERMs the current `say` PID (or signals piper playback to stop) → `OK\t<id>\n`
- `CLEAR\n` → marks every pending item as `skipped` → `OK\t<count>\n`

Cleanup: the daemon registers SIGTERM/SIGINT and unlinks the socket on exit. On startup it checks if the PID in `daemon.pid` is still alive before assuming an orphan socket.

### Queue: SQLite WAL

`~/.cache/agent-tts/queue.db`. Survives daemon crash, reboot, and SKIP. WAL mode lets the worker drain without blocking `agent-tts queue` reads.

Schema (current — v1.10.10 final form, source = `src/queue.zig::SCHEMA`):

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  voice TEXT,
  rate INTEGER,
  state TEXT NOT NULL DEFAULT 'pending',
  enqueued_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER,
  engine TEXT NOT NULL DEFAULT 'say',   -- v0.7 migration
  ssml INTEGER NOT NULL DEFAULT 0,      -- v1.8 migration
  length_scale REAL,                    -- v1.10.7 migration
  noise_scale REAL,
  noise_w REAL,
  tech INTEGER,                         -- v1.10.8 migration
  comma_pause_ms INTEGER,
  sentence_pause_ms INTEGER,
  newline_pause_ms INTEGER,
  speaker_id INTEGER,
  postfx TEXT                           -- v1.10.10 migration
);
CREATE INDEX items_pending_idx
  ON items(state, id)
  WHERE state IN ('pending','playing');
```

NULL is the sentinel for "use voice/env default" on every column added past v0.7 — the worker treats NULL identically to `ipc.Message`'s zero/negative sentinels. Migrations run via `hasColumn` probes + idempotent `ALTER TABLE ADD COLUMN`, so an upgrade from any past schema works in place. `lang` is NOT stored — language is detected per-chunk at synth time and so doesn't survive REPLAY (a future v1.11+ may add it if multi-language replay needs it).

v1.10.12's cadence pass deliberately did NOT add a `cadence` column: cadence is gated on the existing `tech` flag inside `runPiper` (see `src/daemon.zig:621`), so re-enabling cadence on REPLAY costs nothing extra in the schema.

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

Every PCM-producing path (piper fast-lane, piper streaming, piper SSML, cloned sidecar) funnels through a single `playWithPostfx` helper before reaching `audio_player.streamS16leAppend`. That helper is where the v1.10.10 post-fx pipeline plugs in — see [Post-fx pipeline](#post-fx-pipeline-v11010) below. The `say` path bypasses it entirely (no PCM to filter; `say` owns its own playback).

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

**v1.10.11 quality config** — `AudioPlayer.init` now constructs an explicit `zaudio.Engine.Config` instead of passing `null`. Three knobs land at engine create time:

- **Linear resampler LPF order** — `pitch_resampling.linear.lpf_order = 8` (default 0 in miniaudio). Catches the 22050 → 48000 upsample edge for every Sound that mixes through the engine; eliminates sibilant aliasing without measurable CPU cost.
- **Master gain stage** — `engine.setGainDb(-3.0)` drops the f32 mix by 3 dB before the device-format converter. Faber's stressed vowels can push peaks toward 0 dBFS; -3 dB margin avoids hard clipping at the s16 output.
- **Dither intent** — `AGENT_TTS_AUDIO_DITHER` parsed and logged; the Engine doesn't expose `dither_mode` so today this is a no-op declaration. The env knob exists so a future custom `data_callback` over `ma_data_converter` can flip dither without breaking the operator contract.

All three are env-overridable: `AGENT_TTS_AUDIO_LPF_ORDER`, `AGENT_TTS_AUDIO_HEADROOM_DB`, `AGENT_TTS_AUDIO_DITHER`. See [`motor.md`](/agent-tts/motor/#onnx-runtime--miniaudio-quality-v11011) for the research provenance.

### Post-fx pipeline (v1.10.10+)

A fourth box sits between piper's PCM and zaudio: an opt-in ffmpeg subprocess that runs the research-anchored RNNoise + 4-band EQ + de-esser + 2:1 compressor chain. Wiring:

```
piper.synth*  ──► postfx.apply (ffmpeg subprocess)  ──► AudioPlayer.streamS16leAppend
                  └─ chain string built per profile
                  └─ stdin: s16le mono 22050 Hz PCM
                  └─ stdout: filtered s16le PCM
                  └─ stderr: inherited (lands in daemon.log via launchd)
```

The `playWithPostfx` helper in `src/daemon.zig` is the single funnel. Streaming, single-chunk, and SSML piper paths plus the cloned XTTS-v2 path all run through it. `postfx == .off` (the default) is a zero-cost short-circuit: `apply()` returns the original PCM with `was_processed=false`, no subprocess, no allocation.

Four profiles (the per-call `<postfx>` slot in the wire format above):

- `off` — pass-through.
- `clean` — `highpass=80Hz → 2:1 acompressor`. ~30 ms warm.
- `tech` — full research chain (`arnndn=cb.rnnn → highpass=80 → 280Hz shelf +2.5dB → 3.5kHz cut -1.5dB → 10kHz shelf +1.8dB → deesser → 2:1 acompressor`). ~60–90 ms warm.
- `broadcast` — tighter 3:1 compressor for podcasts/announcements.

When ffmpeg isn't on PATH or the RNNoise model is missing, `apply()` falls back to dry PCM silently — postfx is a quality lift, not a hard dependency.

#### v1.10.13 pipe-deadlock fix + 5 s watchdog

v1.10.12 shipped postfx on a serial I/O pump: `writeStreamingAll(stdin) → close(stdin) → drain stdout → wait()`. When a synth produced more PCM than the kernel pipe buffer (~64 KiB on macOS), ffmpeg's output pipe filled before the daemon drained it, ffmpeg blocked on `write(stdout)`, stopped consuming our input, and `writeStreamingAll` blocked on a full input pipe — a classic two-pipe deadlock. The trigger in the user log was `piper-ssml id=207 synth=52427ms` (~2.3 MiB of PCM). The worker thread sat forever; the queue head item never flipped to `done`. See `_qa/v1.10.13-leadtime.md` for the diagnosis.

v1.10.13 in `src/postfx.zig::apply` now spawns three threads around every ffmpeg invocation:

1. **Main thread** — writes `samples` into ffmpeg's stdin in chunks, closes stdin when done.
2. **Drainer thread** — reads ffmpeg's stdout into the result buffer concurrently. Neither pipe ever fills because they're being drained in parallel.
3. **Watchdog thread** — sleeps in 50 ms slices for up to `AGENT_TTS_POSTFX_TIMEOUT_MS` (default 5000). On deadline expiry it `SIGTERM`s ffmpeg, waits 1 s, then `SIGKILL`s if still alive. A `done` atomic retires the watchdog cleanly on healthy completion.

All three threads join before `apply()` returns, so the per-call arena allocations stay valid. On watchdog fire the worker falls through to dry PCM (`was_processed=false`) and logs `[postfx] watchdog killed ffmpeg after 2000ms — fallthrough`. The queue advances either way — the worker's `defer res.queue.finishPlaying(...)` belt-and-braces line (see "Logging & observability" above) guarantees the row flips to `done` even if a downstream call escapes with an error.

The watchdog was live-validated by setting `AGENT_TTS_FFMPEG_PATH=/tmp/fake-ffmpeg.sh` to a script that exec'd `sleep 999` — watchdog killed it after 2000 ms exactly, dry PCM played, queue continued.

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
  main.zig         # entry, argv routing, ttfa-bench + piper-test + voice + mcp + stream
  platform.zig     # comptime OS dispatcher (macos / linux / windows)
  root.zig         # zig-build entry point + module re-exports
  client.zig       # enqueue, queue, skip, clear + pure helpers reused by mcp.zig
  daemon.zig       # accept loop, worker, engine routing, playWithPostfx funnel
  queue.zig        # SQLite WAL wrapper, schema migration (10 columns + index)
  ipc.zig          # 4 → 10 field wire protocol parser, Engine + Lang + Postfx enums
  tts.zig          # spawn `say` (macOS) / `espeak-ng` (Linux) / powershell (Windows)
  piper.zig        # libpiper FFI (GPL-3.0-or-later) + MultiPiperEngine (v1.1)
  audio.zig        # zaudio.Engine wrapper (v1.10.11 LPF + headroom + dither knobs)
  preproc.zig      # Pt-BR cadence + abbreviations + cardinals + chunkSentences (v1.2)
                   # + techPipeline / TECH_GLOSSARY / normalizeIdentifiers / splitCamelCase
                   # + applyCadenceTricks (v1.10.12 SSML cadence pass)
  ssml.zig         # v1.8 — SSML 1.1 subset parser + transpileToSay walker
                   # + v1.10.12 <phoneme alphabet="ipa"> + <sub alias="…">
  detect.zig       # v1.1 — Pt/En stopword-heuristic language detector
  stream.zig       # v1.7 — `agent-tts stream` CLI (stdin streaming chunker)
  postfx.zig       # v1.10.10 — ffmpeg subprocess pipeline (off/clean/tech/broadcast)
                   # v1.10.13 — concurrent drain thread + 5 s watchdog
  log.zig          # v1.10.13 — std.options.logFn sink + rotating file at daemon.log
  launchd.zig      # LaunchAgent install / uninstall / status (macOS)
  systemd.zig      # systemd user unit install / uninstall / status (Linux)
  voice.zig        # v1.4 — `voice clone` / `voice list` / `voice say` subcommands
  mcp.zig          # v1.5 — MCP server (stdio JSON-RPC 2.0); 13 tools as of v1.10.10

scripts/
  voice_clone.py        # v1.4 — XTTS-v2 speaker latent extraction
  voice_synth.py        # v1.4 — XTTS-v2 PCM synthesis to stdout
  setup-voice-clone.sh  # v1.4 — uv venv bootstrap
  install-mcp.sh        # v1.5 — Claude Code MCP config installer
  fetch-voice-en.sh     # v1.1 — Amy En voice
```

Flat. No subdir until it hurts. Cross-check at any time with `ls src/*.zig` — every file in the listing carries the SPDX `MIT OR Apache-2.0` header at line 1 (libpiper-derived code in `piper.zig` is the lone GPL-3.0-or-later exception, gated behind `-Dwith-piper=true`).

## Locked gotchas

- `say -v Luciana` silently fails if the voice is not installed. The daemon validates with `say -v '?'` at boot and logs a warning.
- Orphan socket after SIGKILL — startup checks the PID file before reusing it.
- SQLite without WAL blocks `queue` during `playing`. Always WAL.
- `AudioBuffer.Config.sample_rate` must be set explicitly; the default upsamples to engine rate and shifts pitch.
- espeak-ng (under libpiper) caps phoneme source paths at 160 bytes. Build libpiper in a short path (`/tmp/agent-tts-piper-build`); the vendor script does this for you.
- `char32_t` in `piper.h` fails Zig's `translate-c`. Shim with `@cDefine("char32_t", "uint32_t")` before `@cInclude`.
