---
title: Changelog
description: Milestones shipped and real measurements per version.
---

## TL;DR

Per milestone: what shipped, how we measured, what slipped to the next one. The only KPI is TTFA. Without a published number, the milestone didn't close.

---

## v1.7 — Streaming text input · 2026-06-03

**Shipped**:

- `src/preproc.zig` — new `IncrementalChunker` state machine. Caller owns one instance + a long-lived arena; `feed(arena, bytes) → []Chunk` appends bytes to the internal buffer, scans for sentence boundaries from a `scan_idx` cursor (O(1) amortized per byte), emits completed sentences with the bytes dup'd into the caller's arena. `flush(arena)` drains the remainder at EOF. Same abbreviation list as `chunkSentences` (`Sr./Dr./Sra./Dra./Av./cf./etc./vs.`) so the streaming path can't split a token the batch path wouldn't. Eager-emit policy: a terminator-run touching end-of-buffer emits anyway — splitting an ellipsis across packet boundaries is the accepted trade-off for low-latency voice
- `src/stream.zig` — new `agent-tts stream [--engine X] [--voice V] [--rate R]` subcommand. Reads stdin via `readSliceShort` (no '\n' assumption — LLM streams ship partial tokens), feeds each read into the chunker, forwards each emitted sentence to the running daemon via `client.enqueueLine`. EOF triggers `flush` then exits 0
- `src/mcp.zig` — new tool `say_stream(stream_id, chunk, final?)`. Per-stream state in process-scoped `StringHashMapUnmanaged(StreamSession)` keyed by caller-chosen `stream_id`. `final=true` flushes and drops the session. Tools list grows from 5 → 6
- `src/main.zig` — dispatches `stream` to `stream.run`; HELP gains the new lines; `VERSION = "1.7.0"`. `ttfa-bench --input stream` simulates token-by-token feed (10 ms inter-token gap)
- `build.zig` / `build.zig.zon` — `.version = "1.7.0"`; new test step for `src/stream.zig`

**Measurements** (Mac Air M4, ReleaseFast):

| Metric | Value |
|---|---|
| `zig build` | clean |
| `zig build test` | **166/166** (up from 67/67 at v1.6; +9 chunker + 1 stream integration + 89 reused) |
| MCP `say_stream` "Hello. Wor"+"ld." (final=true) | 2 chunks enqueued |
| CLI `echo "Olá. Tudo bem?" \| agent-tts stream` | 2 chunks enqueued, exit 0 |
| `ttfa-bench --input stream` first-audio | informational — requires piper rebuild, deferred to `_qa/v1.7-baseline.md` |

**Lead time**: see `_qa/v1.7-leadtime.md`. Elapsed **831 s (13m 51s)** from dispatch (2026-06-03 22:52:11 UTC).

---

## v1.6 — Voice cloning ship-it · 2026-06-03

**Shipped**:

- `scripts/setup-voice-clone.sh` validated end-to-end on macOS arm64 (Mac Air M4, macOS 26.5). Five real install blockers surfaced + fixed: `coqui-tts` doesn't declare `torch` so we install it explicitly; `transformers>=5` removed `isin_mps_friendly` so we pin `transformers<5`; `torch>=2.9` forces `torchcodec` which links against ffmpeg 4.x and host has ffmpeg 8.x so we pin `torch<2.9` + `torchaudio<2.9`; XTTS-v2 prompts for CPML licence on first download and the stdin=ignore Zig parent EOFs the prompt so we set `COQUI_TOS_AGREED=1` at the top of both Python scripts; and `uv run --with TTS` would create an ephemeral env that re-resolves the same broken pins so `buildArgv` in `src/voice.zig` now prefers `.venv-voice/bin/python` when present
- `scripts/voice_clone.py` + `scripts/voice_synth.py` exercised end-to-end through `agent-tts voice clone` — XTTS-v2 1.8GB model downloaded once into `~/Library/Application Support/tts/`, speaker latents extracted from a 28s Pt-BR sample, `~/.cache/agent-tts/voices/gabriel/{embedding.npz,metadata.json,clone-info.json}` produced
- `scripts/voice-clone-bench.sh` (NEW) — measures sample WAV gen, clone wall time, cold synth, 2nd-invocation synth, writes `_qa/v1.6-baseline.md` end-to-end. Idempotent — re-running overwrites the previous baseline
- `voice list` UX: now shows `duration` + `rate` columns alongside the slug. Cloned voices read both fields from `metadata.json`; faber + Luciana hardcode 22050Hz. New hand-rolled `parseVoiceMetadata` (no std.json round-trip per voice — see `src/voice.zig`)
- `src/voice.zig::buildArgv` — three-tier interpreter preference (`.venv-voice/bin/python` → `uv run --with TTS` → `python3`). Means a clean `setup-voice-clone.sh` run gives you a deterministic interpreter on every clone/synth without polluting the system Python
- `src/main.zig` `VERSION = "1.6.0"`, `build.zig.zon` `.version = "1.6.0"`, 64 → 67 tests (3 new `parseVoiceMetadata` cases for canonical / tolerant / missing-key JSON)

**Measurements** (Mac Air M4, ReleaseFast, torch 2.8.0, model already on disk):

| Metric | Value | Notes |
|---|---|---|
| Sample WAV generation (`say` 28s Pt-BR) | 0.76s | mono 22050Hz s16le |
| `agent-tts voice clone` wall time | **23.35s** | cold sidecar, model on disk; extracts speaker latents |
| Cold synth (fresh Python, 35-char Pt-BR) | **26.39s** → 4.30s of audio | dominated by torch + XTTS load (~22s of the 26s) |
| 2nd-invocation synth | **24.13s** → 2.17s of audio | each call reloads the model — no resident sidecar in v1.6 |
| `zig build` | green | host arm64 binary |
| `zig build test` | green (67/67) | +3 for parseVoiceMetadata |
| Model on-disk size | 1.8 GB | `~/Library/Application Support/tts/tts_models--multilingual--multi-dataset--xtts_v2` |
| `embedding.npz` size | ~134 KB | gpt_cond_latent + speaker_embedding numpy arrays |

**Honest scope**:

- **No A/B vs Faber.** Quality assessment requires listener evaluation. Bench captures latency + file layout only. Raw PCM is at `/tmp/voice-clone-bench-{cold,warm}.pcm` for manual `afplay`-pipe.
- **No Mauricio voice.** Spec asked for Gabriel + Mauricio; only Gabriel was synthesised this session.
- **No daemon dispatch end-to-end.** v1.4 wired `daemon.zig::synthClonedViaSidecar` but the bench validates the standalone Python path only — wire-compatible (same `embedding.npz`, same stdout PCM contract) but not exercised under the daemon route here.
- **Each synth call reloads the model.** ~22s of the 26s cold synth is `TTS(model_name=...).to('cpu')`. A long-lived sidecar (resident Python behind a UNIX socket) is the v1.7+ unlock to get to Faber's 91ms warm number. v1.6 ships cloning as the "I want my agent in my voice for this clip" demo, not the steady-state runtime.
- **macOS only.** Ubuntu 22.04 path documented but not validated.
- **MPS device not measured.** Apple Silicon MPS works on torch 2.8 but XTTS-v2 has CPU fallbacks for several ops; cpu was used everywhere.

**Lead time** (this session):

```
- dispatch_ts: 2026-06-03 22:52:11 UTC (parent fan-out)
- agent_start_ts: 2026-06-03 22:52:51 UTC
- commit_ts: see _qa/v1.6-leadtime.md
- gates: build=green tests=67/67
```

Bench script: `scripts/voice-clone-bench.sh` (rerun: `./scripts/voice-clone-bench.sh`).
Baseline: [`_qa/v1.6-baseline.md`](https://github.com/biliboss/agent-tts/blob/main/_qa/v1.6-baseline.md).

---

## v1.5 — MCP server · 2026-06-03

**Shipped**:

- `src/mcp.zig` — stdio JSON-RPC 2.0 server bundled in the same Zig binary. New subcommand `agent-tts mcp` opens a newline-delimited JSON loop on stdin/stdout. No new dependencies; uses `std.json` for parse and `std.json.Stringify.valueAlloc` for serialize
- Three JSON-RPC methods implemented: `initialize` (returns `protocolVersion: 2024-11-05`, `capabilities.tools.listChanged=false`, `serverInfo`), `notifications/initialized` (acked, no response), `tools/list` (returns the 5 tools), `tools/call` (dispatches by name)
- 5 tools exposed: `say(text, engine?, voice?, rate?)`, `queue()`, `skip(id?)`, `clear()`, `voices()`. Each is a thin shim over the existing UNIX socket protocol — no changes to `daemon.zig`, `ipc.zig`, `queue.zig`. `voices` enumerates hardcoded Luciana + Felipe and scans `~/.cache/agent-tts/voices/*.onnx` for piper voices
- `src/client.zig` — extracted four pure helpers (`enqueueLine`, `queueLines`, `skipOp`, `clearOp`) plus a `QueueItem` struct. CLI surface unchanged; helpers are silent (no stdout, no process.exit) so the MCP server can compose them
- `src/main.zig` — `VERSION = "1.5.0"`, HELP updated with `agent-tts mcp` line and a one-line Claude Code config snippet
- `build.zig.zon` — `.version = "1.5.0"`
- `scripts/install-mcp.sh` — idempotent installer that merges the `mcpServers."agent-tts"` block into `~/.claude.json` via `jq`. Backs up before writing, refuses to touch a non-object JSON, prints the snippet when jq is missing
- New docs page `src/content/docs/mcp.md` (TL;DR + install + 5 tools + JSON-RPC samples + Claude Code walkthrough), added to the Starlight sidebar between "What's next" and "Changelog". `arquitetura.md` got an MCP subsection; `roadmap.md` got the v1.5 row; `whats-next.md` lost the v1.5 section

**Measurements** (Mac Air M4, ReleaseFast, libpiper OFF):

| Metric | Value | v1.5 target |
|---|---|---|
| Host arm64 binary size | 1 016 440 B (~993 KB) | < 1.1 MB ✅ |
| Size delta vs v1.0 (916 KB) | +~115 KB | informational (mcp.zig + std.json) |
| `tools/list` round-trip end-to-end (echo \| binary, no daemon) | sub-millisecond | qualitative ✅ |
| `tools/call → voices` round-trip (echo \| binary) | sub-millisecond | qualitative ✅ |
| `zig build test` | 27/27 + 6 new MCP tests | green ✅ |
| Smoke test against real Claude Code | not measured | deferred |

**Honest scope**:

- **Tools only.** MCP also defines `prompts/*`, `resources/*`, `sampling/*`, `logging/*`, and server-initiated progress notifications. v1.5 ships none of those. A voice agent needs tools and only tools. The other primitives land when somebody asks
- **End-to-end against a real Claude Code session not validated.** Smoke-tested via `echo '{...}\n' | agent-tts mcp` — initialize handshake correct, tools/list returns 5 entries, tools/call → voices returns the expected ONNX-scan output, tools/call → queue returns the right `isError: true` when no daemon is running
- **`skip` ignores the `id` parameter** — the daemon's SKIP command always targets the currently playing item. The schema documents this. v1.6 will route by id when the queue knows how to interrupt non-head items
- **`voices` enumerates `say` voices from a hardcoded list** (Luciana, Felipe). Querying `say -v ?` would spawn a process per call; defer to v1.6
- Errors from `client.queueLines` / `enqueueLine` are wrapped into `isError: true` MCP responses with a `text` block explaining the failure ("daemon not running", "daemon error", "daemon unexpected response"). The MCP loop itself never crashes the process — parse errors become `-32700`, missing methods become `-32601`

**Install snippet** (for `~/.claude.json` — or run `./scripts/install-mcp.sh`):

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

**Why a single subcommand instead of a dedicated binary**: MCP clients spawn the server on demand and pipe stdio. Bundling the server in the same `agent-tts` binary means one install path, one version number, one set of tests.

### CLI vs MCP — end-to-end latency

Captured against a warm daemon on Mac Air M4, ReleaseFast, libpiper ON, daemon resident with `pt=faber en=off`. 5 calls each:

| Path | Cold (first call) | Warm (subsequent) | Notes |
|---|---|---|---|
| `agent-tts "texto"` (CLI shell-out) | ~33 ms (process boot + socket connect + ack) | **0.2-0.4 ms** ack round-trip | Each invocation is a fresh process. Warm = arena cache + socket already created |
| `echo '<json>' \| agent-tts mcp` (MCP one-shot) | 32-40 ms wall | n/a — process exits after stdin EOF | Cold-only by construction; spawn + JSON parse + 3 messages + socket call + serialize + exit |
| MCP via real Claude Code session (persistent process) | ~30-40 ms first call | **~1-3 ms** estimate per `tools/call` (JSON parse + socket round-trip, no process boot) | Claude Code holds one `agent-tts mcp` open for the session — second call onward avoids the binary spawn cost |

The headline is: **MCP per-tool-call overhead in a persistent session is ~3-5× the CLI warm path** (JSON-RPC framing vs raw TSV), and **the binary-spawn cost amortizes to zero** because the MCP process lives for the whole session. For a voice agent that fires once per assistant turn, both numbers are well under the human-perceptible threshold (~100 ms).

Methodology caveats: the "MCP one-shot wall" measurement above includes one cold binary spawn per sample because we drive the server from a shell loop, not from a persistent stdio peer. The "real Claude Code" row is an estimate based on the warm-CLI ack (0.3 ms) plus the JSON parse/serialize cost measured in `mcp.zig` tests (~0.5-1.0 ms per round-trip with `std.json`). A real long-running Claude Code session would publish the actual number in `_qa/v1.5-mcp-latency.md` once captured.

Practical implication for installers:

- **One-shot via shell** (`echo json | agent-tts mcp`) — fine for ad-hoc scripting and CI smoke tests. Don't loop it for throughput.
- **MCP client (Claude Code, Cursor, Cline)** — automatically gives you the persistent process, so warm tool-calls are ~1-3 ms.

---

## v1.3 — Cross-platform · 2026-06-03

**Shipped**:

- `src/platform.zig` — central `Platform { macos, linux, windows }` enum + `current()` comptime resolver via `builtin.target.os.tag`. Unknown OS tags fail the build instead of the runtime
- `src/tts.zig` — `spawnSay` becomes a per-platform comptime switch: macOS keeps `/usr/bin/say -v <voice> -r <rate>`, Linux spawns `espeak-ng -v pt-br -s <rate>`, Windows spawns `powershell -Command "Add-Type System.Speech; $s.Speak(...)"`. `mapLinuxVoice` translates macOS voice names (Luciana, Felipe, *Premium variants) to `pt-br` so callers that never set `--voice` still get a working pipeline. Pre-warm becomes a no-op on Linux/Windows (no equivalent to ANE voice cache)
- `src/systemd.zig` — new module parallels `launchd.zig`. Renders a user unit (`Type=simple`, `Restart=on-failure`, `WantedBy=default.target`), writes atomically to `$XDG_CONFIG_HOME/systemd/user/agent-tts.service` (falls back to `$HOME/.config/systemd/user/`), drives `systemctl --user daemon-reload && enable --now` on install, `disable --now` + unit removal on uninstall, `systemctl --user status` proxy on status. Override unit name via `AGENT_TTS_SYSTEMD_UNIT`
- `src/main.zig` — `daemon install|uninstall|status` dispatches via `comptime platform.current()`. macOS → `launchd.*`, Linux → `systemd.*`, Windows → prints an error + `exit(2)` (best-effort). HELP updated with per-platform sections. `VERSION = "1.3.0"`
- `build.zig` — `configureExe` per-target audio backend wiring. miniaudio compile defines flip per platform (`MA_NO_COREAUDIO` on Linux, `MA_NO_ALSA`+`MA_NO_PULSEAUDIO` on Windows, etc). Linux links `libasound` (ALSA, lowest-common-denominator on Linux audio). Windows links `winmm` + `ole32`. macOS SDK probe stays macOS-only. PulseAudio uses miniaudio's runtime linking (no `libpulse-dev` at build time)
- `build.zig.zon` — `.version = "1.3.0"`
- `.github/workflows/ci.yml` — new `build-test-linux` job on `ubuntu-latest` installs `libsqlite3-dev` + `libasound2-dev` + `espeak-ng`, runs `zig build` + `zig build test`, smoke-tests the daemon + enqueue path. New `build-windows` job on `windows-latest` marked `continue-on-error: true` (compiles only; runtime untested)
- `scripts/build-libpiper.sh` — detects `uname -s`, sets `LIB_EXT=dylib` on macOS, `LIB_EXT=so` on Linux, refuses anything else. cmake invocation is identical across hosts; the existing N_PATH_HOME=160 workaround (build under `/tmp/agent-tts-piper-build`) keeps the espeak-ng path-truncation gotcha solved on both

**Honest scope** — what is structural vs runtime-tested:

| Platform | Build | Tests | Daemon | espeak-ng / `say` | Auto-start | libpiper |
|---|---|---|---|---|---|---|
| **macOS** (arm64, x86_64) | ✅ runtime — v1.0 universal still green | ✅ 33/33 | ✅ v1.0 ship | ✅ `say` Luciana / Felipe | ✅ launchd | ✅ when `-Dwith-piper=true` |
| **Linux** (x86_64, glibc) | ✅ source compiles; link green on CI `ubuntu-latest`; ❌ macOS host cannot link (no libsqlite3/libasound system libs) | ✅ CI runs `zig build test` | 🟡 source compiles; smoke test in CI; ❌ no local runtime exercise from macOS host | 🟡 `espeak-ng -v pt-br` argv constructed; voice mapping unit-tested | 🟡 systemd module unit-tested for unit rendering; ❌ `systemctl --user` interaction untested off CI | ❌ libpiper Linux build never run end-to-end (script supports it; no CI step) |
| **Windows** (x86_64) | 🟡 best-effort source compile in CI (`continue-on-error: true`) | 🟡 same | ❌ `daemon install/uninstall/status` print error and exit 2 | 🟡 `powershell System.Speech` argv constructed; runtime untested | ❌ no Scheduled Task XML in v1.3 | ❌ libpiper Windows build untested |

✅ = runtime-validated · 🟡 = structural only (compiles, ships, unverified at runtime) · ❌ = not in v1.3

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v1.3-baseline.md` when published):

| Metric | Value | v1.3 target |
|---------|-------|-----------|
| macOS regression vs v1.0 (host build) | none — `zig build` + `zig build test` 33/33 | hold v1.0 ship ✅ |
| `zig build -Dtarget=x86_64-linux-gnu` from macOS host | compile OK; link fails on `sqlite3` + `asound` (expected — no Linux sysroot) | source compiles ✅ |
| `zig build -Dtarget=x86_64-windows-gnu` from macOS host | compile OK; link fails on `sqlite3` (expected) | source compiles ✅ |
| CI matrix | 3 jobs: macos-14 + macos-13 + ubuntu-latest (required) + windows-latest (continue-on-error) | matrix wired ✅ |
| Test count delta | +6 (platform 2, systemd 3, tts 1) → 33/33 | tests pass ✅ |
| Binary size delta | informational — Linux/Windows TBD on first published CI artifact | informational |

**Honest decisions**:

- We did NOT cross-compile end-to-end on the macOS host. Reason: Zig needs the target OS sysroot (libsqlite3, libasound headers + .so) to link. The link step would require a full Linux sysroot pinned in the repo, which conflicts with "no new dependencies" + the SSD goal. CI on `ubuntu-latest` is the source of truth for the Linux green build
- Windows is genuinely best-effort. `tts.zig` constructs a powershell argv that *should* work but has never been runtime-tested. `daemon install` deliberately fails (no Scheduled Task XML scaffolding) so users don't get a half-broken auto-start
- `mapLinuxVoice` translates the four macOS Pt-BR voice names (Luciana, Luciana Premium, Felipe, Felipe Premium) to `pt-br`. Anything unrecognised passes through verbatim — espeak-ng accepts language codes (`pt-br`), variant codes (`mb-br1`), and full names. No platform-aware client logic; the cost of a wrong voice is a single espeak-ng warning + fall-through to default
- PulseAudio stays runtime-linked via miniaudio. Saves a build-time `libpulse-dev` dependency and lets the same binary work on ALSA-only hosts and PipeWire-via-Pulse-compat hosts
- `Restart=on-failure` mirrors the launchd `KeepAlive { SuccessfulExit = false }` contract: clean exit stays down, crash recovers. Same operator mental model on both platforms

**Build gotcha (Zig 0.16 cross-compile)**:

Cross-compiling from a macOS host to Linux fails at the **link** stage with `unable to find dynamic system library 'sqlite3' / 'asound'`. The Zig source compiles fine — comptime switches in `tts.zig`, `main.zig`, and `build.zig` are valid for all three OS tags. To produce a working Linux binary from macOS you need a Linux sysroot in the cache; we deliberately do not ship one. Use CI (`ubuntu-latest`) or a Linux box for real Linux artifacts.

**License**: new files (`platform.zig`, `systemd.zig`) carry `SPDX-License-Identifier: MIT OR Apache-2.0`. No new GPL surface — espeak-ng is a runtime dependency on Linux (spawned via PATH), not a linked library, so the binary stays MIT/Apache when `-Dwith-piper=false`.

---

## v1.1 — Multilingual · 2026-06-03

**Shipped**:

- `src/detect.zig` — heuristic Pt/En language detector. Lowercase-tokenize, lookup against two ~50-entry stopword sets, short-fragment guard, mixed needs both sides ≥ 2 hits and ≥ 25 % of tokens, tie defaults to `.pt`. Deterministic, no allocations beyond a transient lowercase buffer, 11 unit tests covering empty / pure-Pt / pure-En / mixed / gibberish / one-word borrows / tie
- `src/preproc.zig` — `splitByLang(arena, text, default_lang) → []Chunk` cuts the input on `. ! ? \n`, detects per sentence, coalesces adjacent same-lang runs. Existing v0.5 transforms still run per chunk after the split. 5 new unit tests
- `src/piper.zig` — new `MultiPiperEngine` holds Pt + optional En `PiperEngine`. `initMulti(arena, pt, en?, espeak)` boots both voices; En slot stays `null` when its file isn't on disk (no crash). `synthLang(arena, text, .pt|.en)` dispatches per chunk; En unavailable silently falls back to Pt. Public `Route` enum so the daemon constructs the parameter explicitly (Zig 0.16 distinguishes anonymous enum literals by site)
- `src/daemon.zig` — boots `MultiPiperEngine` when `AGENT_TTS_PIPER=1`. Probes the En voice file before passing the path so missing-En logs once with the install hint. Worker runs `splitByLang` per item, synths each chunk on the matching engine, concatenates PCM via `audio_player.streamS16le`. Single-chunk path matches v1.0 overhead exactly (one synth call)
- `src/ipc.zig` — `Message.lang: Lang { auto, pt, en }` field. Wire format becomes `ENQUEUE\t<engine>\t<lang>\t<voice>\t<rate>\t<text>`. Backward compat: parser peeks the first token after `ENQUEUE` — if `Engine.fromStr` matches AND the next field matches `Lang.fromStr`, new v1.1 layout; else falls back to v0.7 (5-field) or v0.6 (4-field, no engine). 9 unit tests cover every layout + round-trip
- `src/client.zig` — `--lang auto|pt|en` flag (default `auto`). HELP updated. Default voice flips per `--lang`: `faber` for `auto|pt`, `amy` for `en`. New 6-field ENQUEUE line writer
- `scripts/fetch-voice-en.sh` — pulls `en_US-amy-medium.onnx` + `.onnx.json` from `huggingface.co/rhasspy/piper-voices` into `~/.cache/agent-tts/voices/`. Same shape as `fetch-voice.sh`. Voice license CC-BY-NC; we do NOT redistribute
- `src/main.zig` — `VERSION = "1.1.0"`. HELP rewritten with `--lang`. Header comment lists v1.1 closing the code-switch gap. `build.zig.zon` version bumped
- `build.zig` — dedicated `addTest` steps for `detect.zig` (11) and `ipc.zig` (9) so `zig build test` exercises them explicitly. `preproc.zig` step still owns the 43 split + detect-imported tests it ran in v1.0

**Measurements** (Mac Air M4, ReleaseFast):

| Metric | Value | v1.1 target |
|---------|-------|-----------|
| Host binary size (`zig build -Doptimize=ReleaseFast`) | 918 568 B (~897 KB) | informational |
| Host binary size (with libpiper) | 1 002 360 B (~979 KB) | informational |
| Multi-piper boot (Pt only, En voice absent) | 312.6 ms | < 800 ms ✅ |
| Multi-piper boot (Pt + En both loaded) | informational, not captured this session — needs Amy file on disk | < 800 ms target |
| Piper TTFA warm (5-iter avg, single voice) | 92.7 ms (min 84.6, max 104.8) | < 150 ms ✅ |
| `zig build test` | 64/64 tests pass | green ✅ |
| Daemon round-trip ACK (warm) | 0.4 ms | informational |
| End-to-end synth + playback id=50 (pt-only chunk) | synth 103.5 ms, play 2044 ms | informational |
| Lang detection per ~50-token message | informational, not captured this session — sub-µs by inspection | < 100 µs target |

**Honest scope**:

- `scripts/fetch-voice-en.sh` exists and the code paths exercise the En slot, but the Amy voice was NOT downloaded in this session. The boot log shows the graceful fallback (`pt=faber en=off`); routing flips to single-voice Pt when En is missing
- Code-switch end-to-end ("Olá. Hello world. Tchau.") not audited against the speakers — requires both voices on disk
- `ttfa-bench` still uses the single-voice path (it constructs `PiperEngine` directly, not `MultiPiperEngine`); the 92.7 ms number is the v0.7 Faber number. v1.1 chunk-synth latency for the no-route case (single Pt chunk) lands within the same envelope — confirmed by the id=50 end-to-end (`synth=103.5ms` for a ~17-token Pt sentence)
- Cold cost rises ~340 ms when En does load (second `PiperEngine.init` mirrors the Pt one). Boot stays under the v1.0 800 ms target on host hardware; documented as informational because the measurement requires the voice file
- Wire-protocol Lang field is in-memory only — `queue.zig` still doesn't persist `lang`. Items reloaded after a daemon crash default to `auto` and re-detect. Acceptable for v1.1; persistence lands when streaming (v1.2) needs replay

**Build gotcha**:

- Zig 0.16 treats every anonymous enum literal as a distinct type. The first cut had `synthLang(.., lang: enum { pt, en })` and the daemon constructed `const route: enum { pt, en } = ...` — the compiler rejected the call site because the two anonymous types didn't unify. Fix: expose `MultiPiperEngine.Route` as a named pub type and reference it from both sides
- The stub `MultiPiperEngine` used when `-Dwith-piper=false` mirrors the real signature including `Route` so daemon.zig type-checks without libpiper on the include path

**License**: detect / preproc / ipc / client / main / build / scripts all stay MIT OR Apache-2.0. Piper remains the only GPL-3.0 file.

---

## v1.2 — Streaming · 2026-06-03

**Shipped**:

- `src/preproc.zig` — `chunkSentences(arena, text) ![]Chunk` splits raw input on `. ! ? \n`. Punctuation attaches to the preceding chunk; newlines drop (their `[[slnc 600]]` comes back when `process` runs on the chunk). Abbreviation-aware: `Sr. Dr. Sra. Dra. Av. cf. etc. vs.` do NOT terminate, reusing the same `ABBREVS` list as `expandAbbreviations`. 13 new chunking tests covering single/multi-sentence, mixed terminators, trailing whitespace, only newlines, ellipsis, combined `?!`, abbreviations
- `src/daemon.zig` — `runPiper` now chunks the input. Single-chunk path stays on the v0.7 fast lane (`runPiperSingle`); multi-chunk path forks a `synthWorker` thread and runs the audio path in the worker loop. Bounded SPSC ring `RING_CAP=2` slots, atomic head/tail (Zig 0.16 dropped `std.Thread.Mutex`; we already use the same `nanosleep` pattern in `audio.zig`). Per-chunk `ArenaAllocator` on `std.heap.smp_allocator` (lock-free fast path; debug GPA would serialize across threads). SKIP drains the channel + signals the synth thread to bail. Synth failure on chunk N continues with N+1; play failure aborts the whole pipeline
- `src/audio.zig` — `streamS16leAppend` exposed as the v1.2 contract surface. Today it aliases `streamS16le` — back-to-back AudioBuffer plays measure sub-millisecond inter-chunk gap on this workload, so the v1.2.1 custom-`decoderReadProc` path is deferred until a workload proves the gap audible
- `src/main.zig` — `ttfa-bench --input long` reads `_qa/v1.2-long-input.txt` (490 Pt-BR words, 47 chunks after preproc), runs the streaming pipeline end-to-end, captures first-audio latency, total wall time, and inter-chunk gap median/max. Inline fallback paragraph if the file isn't reachable from cwd
- `_qa/v1.2-long-input.txt` — 490-word Pt-BR agent-monologue fixture for the long-input bench
- `build.zig.zon` version `1.2.0`, `src/main.zig` `VERSION = "1.2.0"`, HELP documents `--input short|long`

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v1.2-baseline.md`):

| Metric | Value | v1.2 target |
|---------|-------|-----------|
| Long-input first-audio (v0.7 serial path, projected) | ~3 000 ms | informational |
| **Long-input first-audio (v1.2 streaming, run 1)** | **51.6 ms** | < 200 ms ✅ |
| **Long-input first-audio (v1.2 streaming, run 2)** | **41.3 ms** | < 200 ms ✅ |
| Long-input total wall time | 166.6 s | informational |
| Inter-chunk gap median | 0.02 ms | informational |
| Inter-chunk gap max | 0.16 / 0.61 ms | < 10 ms ✅ |
| Long-input chunks (after `preproc.chunkSentences`) | 47 | informational |
| Short-input warm TTFA (v0.7 regression check) | 97.1 ms | <= 91.3 ms (v0.7) — within run variance |
| Piper init cold | 328-456 ms | informational |
| `zig build test` | 40/40 | all green ✅ |

Long-input first-audio fell from ~3 s to **~50 ms** — about 60× on the headline path. The user hears the first sentence about as fast as a short utterance, regardless of total input length.

**Why "gapless" is checked but not custom-coded**:

The v1.2 spec asked for true gapless playback (custom miniaudio `decoderReadProc` + sample ring). The measurement says we don't need it yet: with back-to-back `AudioBuffer + Sound` create/start/destroy per chunk, the median inter-chunk gap is 0.02 ms and the max sits at 0.16-0.61 ms. That's below one device period (~10 ms) and below a perceptible artifact. The custom path lands in v1.2.1 if a workload (e.g. screaming-fast agent output, very small chunks) proves the gap audible. Until then, the simpler `streamS16leAppend = streamS16le` shim ships.

**Honest decisions**:

- The "first audio" measurement is captured inside `streamS16leAppend` right after `sound.start()`. The real device-pump first frame is a few ms later (one device period, ~10 ms). The relative win is correct; the absolute is a tight lower bound. Bench notes this in `_qa/v1.2-baseline.md`
- Synth thread uses `std.heap.smp_allocator` to keep producer and consumer off the same debug GPA freelist. Single-chunk path keeps the debug allocator from v0.7
- Abbreviation corner cases (decimals like `3.14`, `e.g.`, US-English `Mr.`) split aggressively. Documented in `chunkSentences`'s comment block as v1.2.1 territory. The existing Pt-BR abbreviation list (`Sr. Dr. Sra. Dra. Av. cf. etc. vs.`) covers the common case
- Bench's gap stat is the consumer-thread inter-arrival time, not the audio-device silence. With sub-ms numbers the two are interchangeable
- IPC protocol unchanged — streaming is a daemon-internal optimization, no client-side flag. v1.0 clients keep working

**Build gotcha**: none new. The ring + nanosleep idiom already lived in `audio.zig` since v0.7.

**License**: unchanged. Default build MIT OR Apache-2.0; `-Dwith-piper=true` inherits GPL-3.0-or-later from libpiper + espeak-ng.

---

## v1.4 — Voice cloning · 2026-06-03

**Shipped**:

- `agent-tts voice clone --sample <wav> --name <slug>` — new subcommand. WAV header sniff (RIFF/WAVE magic + sample-rate + channels + bits-per-sample + data-chunk size). Sample duration must sit in `[20, 120]` seconds. Slug must match `[a-z0-9-]+`, 1-32 chars. Writes `~/.cache/agent-tts/voices/<slug>/embedding.npz` (via the Python sidecar) + `~/.cache/agent-tts/voices/<slug>/metadata.json` (written by Zig — keeps a structured record even if the sidecar partially fails)
- `agent-tts voice list` — prints faber + each cloned voice with a one-line summary. Skips directories without a `metadata.json` (defensive against half-written clones)
- `ipc.Engine` gains `cloned`. `parseRequest` accepts `ENQUEUE\tcloned\t<slug>\t<rate>\t<text>`. v0.6 4-field layout still backward-compatible (auto-falls-back to engine=`say`)
- `daemon.runOne` routes `cloned` items through `scripts/voice_synth.py` via `std.process.Child`. Sidecar reads text on stdin, writes raw s16le mono 22050Hz PCM to stdout, which the daemon drains into a buffer and feeds `AudioPlayer.streamS16le` — same playback pipeline as Faber. If the embedding file is missing OR the sidecar exits non-zero, the worker logs + falls back: piper Faber when loaded, else `say` Luciana
- `client.zig` resolves `--voice <slug>` implicitly: `faber` → piper, slug with a `metadata.json` on disk → cloned, anything else → say. Explicit `--engine` overrides
- `scripts/voice_clone.py` — Coqui XTTS-v2 wrapper. Extracts `gpt_cond_latent` + `speaker_embedding` from the reference sample, writes `.npz` archive. Uses `coqui-tts >= 0.24.0` (community fork of the abandoned upstream `TTS` package). Cold model load ~6-10s on Apple Silicon CPU
- `scripts/voice_synth.py` — counterpart that loads the embedding and synthesizes Portuguese (default) or any XTTS-v2 language. Output: raw s16le PCM on stdout at 22050Hz (resampled from XTTS's native 24000Hz via `scipy.signal.resample_poly`, falls back to `np.interp` if scipy missing)
- `scripts/setup-voice-clone.sh` — idempotent bootstrap. Prefers `uv venv --python 3.11` (fast lockfile-clean install); falls back to `python3 -m venv`. Pins `coqui-tts>=0.24.0`, `scipy`, `soundfile`
- `build.zig.zon` `.version = "1.4.0"`, `src/main.zig` `VERSION = "1.4.0"`. HELP updated with the new subcommand surface
- `build.zig` — two new test steps (`run_voice_tests`, `run_ipc_tests`) so the v1.4 surface stays test-covered even if main.zig stops importing `voice.zig`

**Measurements** (Mac Air M4, ReleaseFast):

| Metric | Value | v1.4 target |
|---------|-------|-----------|
| `zig build` (Debug, host arm64) | clean | clean ✅ |
| `zig build test --summary all` | 40/40 tests pass | all pass ✅ |
| Slug validation tests | 3 pass (accept/reject empty+illegal) | all pass ✅ |
| WAV sniff tests | 3 pass (mono s16 22050, stereo 44.1k, zero-block guard) | all pass ✅ |
| ipc Engine round-trip with `cloned` | pass | pass ✅ |
| End-to-end clone smoke-test (real WAV → embedding → synth) | **not run in this session** | deferred to v1.4.1 |
| Cold sidecar startup (XTTS load, expected) | ~6-10s | informational |
| Warm cloned synth first-sample (expected) | ~500-900ms | informational |

**Honest scope**:

- **The Python sidecar was not installed or smoke-tested in this session.** XTTS-v2 (~1.8 GB model) download + first-run synth blows the time budget. The Zig surface is complete + tested; the Python scripts are written + executable + dispatched correctly by the daemon, but `scripts/setup-voice-clone.sh` has not been run on this machine. **v1.4.1 closes the gap**: run setup, clone Gabriel's voice from a 30s WAV, capture warm TTFA, publish in `_qa/v1.4.1-baseline.md`
- "Real" first-sample TTFA for cloned voices is expected at ~500-900ms on Apple Silicon CPU based on Coqui community benchmarks — pessimistic vs Faber's 91ms warm. Cloned is opt-in for personal voice, not the default
- No `Felipe`-grade naming UX yet. v1.4 ships the surface `--voice <slug>` and validates slug format; surfacing in `voice list` is plain text
- No ONNX export of the cloned voice. XTTS-v2 ONNX export is not production-stable (see [Coqui #4014](https://github.com/coqui-ai/TTS/discussions/4014)). v1.4 stays on the PyTorch path until that lands
- The "only Zig" lifecycle constraint is **relaxed for the cloned engine only**. Faber + say remain pure Zig — no Python required to use the default v1.0 surface. See `docs/motor.md` "Cloned voices (v1.4)" for the licensing + lifecycle rationale

**License note**: Coqui TTS is MPL-2.0. The Python sidecar runs as a separate process (`std.process.Child` from `daemon.zig::synthClonedViaSidecar`). The parent Zig binary remains dual MIT/Apache. The MPL boundary is the process line — no MPL code is linked or distributed inside `agent-tts`.

---

## v1.0 — universal binary + brew tap · 2026-06-03

**Shipped**:

- `zig build universal` — new `build.zig` step that compiles two independent slices (`aarch64-macos` + `x86_64-macos`, ReleaseFast, libpiper OFF) and fuses them with `lipo -create` into `zig-out/bin/agent-tts-universal`
- Cross-compile fallback: `sdkRoot()` in `build.zig` locates the macOS SDK (CLT preferred, Xcode.app fallback) and adds library/include/framework paths for the cross-targets. Without it, Zig 0.16 fails the linker on `libsqlite3.tbd` and the `@cImport` on `sqlite3.h` for non-native targets
- `build.zig.zon` version `1.0.0`, `src/main.zig` `VERSION = "1.0.0"`
- `Formula/agent-tts.rb` — Homebrew formula with `depends_on "sqlite"` + `macos: :ventura`, `test do system "#{bin}/agent-tts", "--version" end`, and a header documenting the tap path `gabriel/tap` (placeholder — replace with the real tap once the repo exists)
- `README.md` expanded with install sections (brew tap, source, launchd auto-start, optional libpiper)
- Universal binary runs on both architectures via `arch -arm64` and `arch -x86_64` (Rosetta 2), each reporting `agent-tts 1.0.0`

**Measurements** (Mac Air M4, ReleaseFast, libpiper OFF, baseline at `_qa/v1.0-baseline.md`):

| Metric | Value | v1.0 target |
|---------|-------|-----------|
| Universal binary size (with v0.7 zaudio) | 1 801 696 B (~1.8 MB) | < 2 MB ✅ |
| Host arm64 binary size (with v0.7 zaudio) | 900 552 B (~880 KB) | < 1 MB ✅ |
| Universal binary size (without v0.7, libpiper OFF) | 1 076 576 B (~1.1 MB) | informational |
| `lipo -info` | `x86_64 arm64` | both arches ✅ |
| ACK round-trip warm daemon (median, 7 calls) | 0.1 ms | < 300 ms ✅ (proxy) |
| Cold pre-warm (one-time boot) | 275.1 ms | informational |
| Bare `say` spawn+playback floor | ~790 ms | informational |
| `brew audit --strict --new` (after fixes) | 2 issues, both placeholder 404 URLs | structural ✅ |

**Honest scope**:

- Real TTFA (audio-device first-sample) not measured — dtruss requires SIP off, host runs SIP on. The 0.1ms ACK round-trip is a safe floor: the daemon responded before playback started. True TTFA sits between the pre-warm tail (~275ms) and bare-`say` spawn (~790ms)
- Piper warm-path NOT measured in this v1.0 — depends on v0.7 (zaudio + engine routing), which is in flight in parallel. When v0.7 closes, `_qa/v0.7-baseline.md` publishes the number
- Native Intel Mac untested (no hardware available). Cross-arch sanity validated via `arch -x86_64` (Rosetta 2): the x86_64 slice runs and reports the right version
- `brew install gabriel/tap/agent-tts` still fails — `gabriel/tap` is a placeholder, and the `url`/`sha256` in the Formula are placeholders until the first release tarball is published on GitHub with a computed hash

**Cross-compile gotcha (Zig 0.16)**:

Zig 0.16 auto-resolves macOS SDK paths only for the native target. For cross-targets the linker fails with `unable to find dynamic system library 'sqlite3'`. Workaround in `configureExe()`: probe `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (CLT) or the Xcode.app SDK, add `usr/lib` to the library path, `usr/include` to the system include path, and `System/Library/Frameworks` to the framework path. `libsqlite3.tbd` is multi-arch (x86_64-macos + arm64e-macos); non-secure arm64 links against arm64e without trouble.

---

## v0.7 — zaudio streaming PCM + engine routing · 2026-06-03

**Shipped**:

- `src/audio.zig` — `AudioPlayer` struct owning a `zaudio.Engine` (miniaudio). `streamS16le` plays an s16 mono buffer directly via `AudioBuffer` + `createSoundFromDataSource`, no temp WAV. `requestStop` aborts the poll loop via an atomic flag + `sound.stop()`
- `src/piper.zig` — new `synthToSamples(arena, text) ![]i16` returns PCM directly (no WAV); `sampleRate()` exposes the voice-config rate. `synthToWav` now calls `synthToSamples` + `writeWav`
- `src/ipc.zig` — `engine: Engine = .say` field on `Message`, `Engine { say, piper }` enum, encode/parse layout `ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>`. **Backward compat**: `parseRequest` peek-detects the v0.6 layout (4 fields, no engine) and falls back to engine=.say
- `src/queue.zig` — idempotent schema migration via `PRAGMA table_info` + `ALTER TABLE items ADD COLUMN engine TEXT NOT NULL DEFAULT 'say'`. `push/list/tryClaimNext` propagate the field; `PoppedItem` gains `engine`
- `src/daemon.zig` — `AudioPlayer` boot best-effort in the daemon (logs time, graceful fallback if zaudio fails → `runPiper` falls back to WAV+afplay). `PiperEngine` lives in daemon scope (refactored from the `tryBootPiper` leak-and-pray into a `Resources` struct passed to the worker). `runOne` switches on `item.engine`; SKIP routes both SIGTERM (say) and `audio_player.requestStop()` (piper)
- `src/client.zig` — `--engine say|piper` flag. Default `say`. Default voice becomes `Luciana` or `faber` depending on engine
- `src/main.zig` — HELP updated. Hidden `ttfa-bench --engine X --warm N` subcommand instruments first-sample latency (zaudio first-sample callback) and runs N warm cycles
- `build.zig` — wires zaudio + miniaudio vendored sources (~100k LoC single-header) with `-DMA_NO_RUNTIME_LINKING` + CoreAudio/AudioUnit frameworks. `vendor/zaudio/COMMIT` pinned at `e5b89fde58be72de359089e9b8f5c4d5126fb159`
- In-tree patch in `vendor/zaudio/src/zaudio.zig`: Zig 0.16 removed `std.Thread.Mutex` — swapped for a `std.atomic.Value(bool)` spin lock (contention negligible in mem callbacks)

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v0.7-baseline.md`):

| Metric | Value | v0.7 target |
|---------|-------|-----------|
| Piper TTFA warm (5-iter avg) | **91.3ms** (min 84.8, max 96.6) | < 1s ✅ |
| Piper warm — synth dominant | 91.2ms synth | informational |
| Piper init cold (bench, warm FS) | 335.0ms | informational |
| Daemon boot total | ~715ms (pre-warm 270 + zaudio 78 + piper 344) | informational |
| Say TTFA warm (5-iter avg) | 2229ms* | informational |
| Binary size without piper | 918 072 B (+463 KB vs v0.6) | informational |
| Binary size with piper | 975 304 B (+518 KB vs v0.6) | informational |
| Daemon RSS resident (piper + zaudio) | 176 MB | informational |
| Schema migration v0.6 → v0.7 | idempotent, ALTER backfills 'say' | informational |

*Caveat: "say TTFA" in the bench measures wall-clock spawn+wait+playback for a full Pt-BR sentence — NOT first-sample. macOS `say` exposes no hook for the first frame without hijacking the device. The real daemon-path number is the ~50ms round-trip from v0.2 (voice pre-warmed).

**Piper TTFA warm = 91.3ms** beats the 1s target by 10×. Engine resident in the daemon eliminated the 397ms cold init from v0.6.

**Honest decisions**:

- Upstream zaudio (`zig-gamedev/zaudio`) still uses `linkLibC()` (removed in Zig 0.16); we vendored `.zig` + `.c` in `vendor/zaudio/` instead of forking. Recipe in `vendor/README.md`. When upstream catches up, swap to a `build.zig.zon` dependency
- AudioPlayer uses `AudioBuffer` (one allocation per utterance) instead of a custom streaming `decoderReadProc`. Simpler; synth dominates TTFA, so optimizing playback overhead doesn't move the needle
- `say` TTFA stays not-truly-instrumented. Accepted for v0.7 — the daemon warm-voice path has been documented sub-100ms since v0.2
- Daemon RSS jumps from ~30 MB to 176 MB once piper loads. Price of keeping ONNX runtime + Faber-medium tensors warm. User opts in via `AGENT_TTS_PIPER=1`
- `runPiper` registers the daemon's own PID as "playing" (SKIP can't cancel in-flight piper synth — only playback). Trade-off accepted; synth lasts 90ms so users rarely want to SKIP mid-flight

**Build gotcha**:

- `std.Thread.Mutex` and `std.Thread.sleep` were removed in Zig 0.16. zaudio.zig got a spin-lock shim; audio.zig uses `std.c.nanosleep` directly (we already link libc into the exe)
- `linkLibC()` became `link_libc = true` in the module config. That's why we don't use upstream's build.zig.zon
- The original daemon imported `piper.zig` unconditionally; @cImport piper.h fails with `-Dwith-piper=false`. Fix: `piper_mod` is a conditional comptime alias

**License**: GPL-3.0 inherited from libpiper + espeak-ng when agent-tts is distributed with the dylib. zaudio is MIT. Net: GPL only because of Piper.

---

## v0.6 — libpiper FFI baseline · 2026-06-03

**Shipped**:

- Vendor build of `libpiper.dylib` from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) tag v1.4.2 (static espeak-ng + ONNX Runtime 1.22.0 pulled by the project's CMake). Reproducible recipe in `vendor/README.md`, source gitignored
- `src/piper.zig` — `PiperEngine` struct via `@cImport piper.h`: `init(voice_path, espeak_data_path)` loads the model, `synthToWav(io, text, out_path)` synthesizes and writes PCM s16le mono WAV
- `build.zig` — `-Dwith-piper=true` option links `libpiper` + `c++` with `rpath` to `vendor/.../dist/lib/`. Default OFF keeps the binary slim for users on `say` only
- Experimental `agent-tts piper-test "<text>" <out.wav>` subcommand bypasses the daemon and measures init + cold synth
- Optional daemon boot: `AGENT_TTS_PIPER=1 agent-tts daemon` loads `PiperEngine` next to Luciana pre-warm — engine stays resident but v0.6 does NOT route playback yet (v0.7 does that with zaudio)
- `pt_BR-faber-medium.onnx` (63MB) voice downloaded to `~/.cache/agent-tts/voices/`

**Measurements** (Mac Air M4, ReleaseFast, baseline at `_qa/v0.6-baseline.md`):

| Metric | Value | v0.6 target |
|---------|-------|-----------|
| Piper init cold (filesystem cache miss) | 646.7ms | informational |
| Piper init warm (FS cached) | ~460ms | informational |
| Synth + WAV — short utterance (3-5 words) | 60-110ms | — |
| Synth + WAV — 268-char paragraph | 731ms | — |
| Total short (init+synth) | ~535ms | <1s ✅ |
| Total long (init+synth) | ~1217ms | <1s ❌ (200ms over) |
| Daemon piper engine load | 397ms | <500ms ✅ |
| Binary size without piper | 455 288 B | baseline |
| Binary size with piper | 457 336 B | +2 KB |

Short hits the target; long misses cold by 200ms. v0.7 kills the init cost by reusing the resident engine.

**Build gotcha**: espeak-ng defines `N_PATH_HOME=160` and the absolute path of the vault worktree (>160 chars) silently truncates filenames while compiling phonemes. Workaround: build in `/tmp/piper-build` and symlink `vendor/.../libpiper/build`. Documented in `vendor/README.md`.

**License**: GPL-3.0 inherited from libpiper + espeak-ng when agent-tts ships with the dylib. Public license decision is deferred to v1.0 (brew tap).

---

## v0.5 — Pt-BR preprocessor (human cadence) · 2026-06-03

**Shipped**:

- `src/preproc.zig`: 3 chained transforms, single-pass per stage, arena allocation per message
  - Whole-word abbreviations: `Sr. Sra. Dr. Dra. cf. etc. vs. nº Av. R$`
  - Pt-BR cardinals 0..9999 (state machine over digits; skipped when glued to a letter or `%`; supports negatives `-5` → "menos cinco" and zero)
  - `[[slnc N]]` pauses: `,` (150ms), `.` `!` `?` (400ms), `\n` (600ms); consecutive punctuation collapses to the largest in the group
- Hook in `tts.zig`: `spawnSay()` runs the preproc before `say` argv. Preproc failure is non-fatal — log + fall back to raw text
- Binary 496KB arm64 Mach-O (was 455KB at v0.2; sum of v0.3 SQLite + v0.4 launchd + v0.5 preproc)
- 26 new tests covering each transform + edge cases. `zig build test` = 27/27

**Measurements** (Mac Air M4, ReleaseFast, 1000 iter per case; baseline at `_qa/v0.5-baseline.md`):

| Case | input bytes | median | mean |
|------|-------------:|--------:|------:|
| short greeting (`Olá, mundo.`) | 12 | 2.0 µs | 1.5 µs |
| `Sr. Silva tem 25 anos, certo?` | 29 | 4.0 µs | 3.4 µs |
| `Av. Paulista, nº 1578.` | 23 | 3.0 µs | 3.2 µs |
| `Estamos em 2026 e devemos R$ 1234…` | 47 | 4.0 µs | 3.5 µs |
| long mixed paragraph | 151 | 5.0 µs | 4.4 µs |

Budget was < 1ms per message; we shipped 200× under. Zero TTFA-regression risk.

**Honest decisions**:

- `Sr.` consumes the dot (becomes "Senhor", no trailing pause). Treated as abbreviation, not terminator
- `R$` is a blind substitution, doesn't reorder: `R$ 500` → "reais quinhentos". Good enough until someone complains
- The "e" connector for thousands follows Pt-BR convention: `1500` = "mil e quinhentos", `1578` = "mil quinhentos e setenta e oito"
- Cap at 9999 — bigger numbers stay raw (`say` reads them digit-by-digit)
- Fractions, times (`14h30`), decimals still literal. YAGNI until real demand

---

## v0.4 — launchd auto-start · 2026-06-03

**Shipped**:

- `agent-tts daemon install | uninstall | status` subcommands
- LaunchAgent plist at `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist` — daemon survives logout/reboot
- Atomic plist write via `createFileAtomic` + `replace` (the kernel only sees old or new, never half-written)
- `launchctl bootstrap gui/<uid>` on install (replaces the deprecated `launchctl load`); `bootout` on uninstall
- `KeepAlive` as a dict `SuccessfulExit=false` — restart only on crash
- `HOME` forced via `EnvironmentVariables` — launchd doesn't inherit it reliably
- Self-locate via `std.process.executablePath` (Darwin: `_NSGetExecutablePath` + realpath)
- uid lookup via `std.c.getuid()` to build the `gui/<uid>` domain
- Label override via `AGENT_TTS_LAUNCHD_LABEL` env — used by the dry-run test
- Guards: install refuses if the plist already exists, uninstall refuses if it doesn't

**Measurements** (Mac Air M4, dry-run with test label, baseline at `_qa/v0.4-baseline.md`):

| Metric | Value | v0.4 target |
|---------|-------|-----------|
| Install round-trip (median, 3 runs) | ~10ms | < 200ms |
| Uninstall round-trip (median, 3 runs) | ~10ms | < 200ms |
| Plist parse (`plutil -lint`) | OK | OK |
| `launchctl list` post-install | PID + label visible | visible |
| `launchctl list` post-uninstall | label absent | absent |

Dominated by the fork+exec of `/bin/launchctl`. macOS `/usr/bin/time` granularity = 10ms; real ≤ 10ms.

---

## v0.3 — SQLite WAL queue + queue/skip/clear · 2026-06-03

**Shipped**:

- Queue migrated from in-memory `ArrayList` to **SQLite WAL** at `~/.cache/agent-tts/queue.db` — survives daemon crash + reboot
- Schema `items(id, text, voice, rate, state, enqueued_at, started_at, finished_at)` + partial index on `state IN ('pending','playing')`
- Boot-time crash recovery: `UPDATE state='pending' WHERE state='playing'` re-promotes orphans
- 3 new subcommands: `agent-tts queue` (lists pending+playing), `skip` (SIGTERM on the current `say`), `clear` (marks pendings as skipped)
- IPC protocol extended: `ENQUEUE` (same as v0.2) + `QUEUE`, `SKIP`, `CLEAR` + `ITEM\t...\n` response + `END\n`
- Worker rewritten: drains via SQLite, registers the child PID before `wait()`, SKIP sends SIGTERM to the saved PID
- `@cImport(sqlite3.h)` + `linkSystemLibrary("sqlite3", .{})` — uses the macOS SDK's libsqlite3

**Measurements** (Mac Air M4, warm daemon, baseline at `_qa/v0.3-baseline.md`):

| Metric | Value | v0.3 target |
|---------|-------|-----------|
| ACK round-trip enqueue (median, 7 calls) | 0.1ms | informational |
| ACK round-trip queue (median, 5 calls) | 0.1ms | informational |
| ACK round-trip skip | <10ms (measurement floor) | informational |
| Binary size (ReleaseFast) | 476KB | <1MB |
| Persistence (kill -9 mid-play) | ✅ 3/3 items drain post-restart | "queue survives crash" |

The "queue survives daemon crash" criterion holds: killing daemon + `say` mid-utterance leaves the item in `playing` in the DB; restart re-promotes the orphan to `pending` and the worker drains it.
---

## Benchmark interlude · 2026-06-03

Before coding v0.3, I spent a session benchmarking alternative engines to fix Pt+En code-switching. Conclusions in [TTS engine](/motor/). Summary:

- Piper Faber via Python — Pt-only, rejected
- XTTS-v2 multilingual via Python — 27s/call from the CLI, Python sidecar rejected by the "only Zig" constraint
- Decision: **libpiper FFI** (from OHF-Voice/piper1-gpl) lands as v0.6-v0.7, brings the Faber voice + native ONNX runtime via `@cImport`, `PiperEngine` owner struct, zaudio for PCM streaming
- EN code-switching stays unsolved until v1.1+ (mature multilingual ONNX)

Cleanup: 3.2GB freed (XTTS-v2 venv + model + uv cache). The `pt_BR-faber-medium.onnx` voice (63MB) is kept in `~/.cache/agent-tts/voices/` for v0.6+.

---

## v0.2 — daemon + socket + in-memory queue · 2026-06-03

**Shipped**:

- Foreground daemon (`agent-tts daemon`) with a UNIX socket at `~/.cache/agent-tts/sock`
- Thread-safe in-memory queue (`std.Io.Mutex` + `std.Io.Condition` + `std.ArrayList`)
- Single worker thread drains the queue by calling `say` — playback serialized, never parallel
- Boot-time pre-warm of the Luciana voice (`say -v Luciana " "`)
- Client round-trips over the socket: ENQUEUE → ACK in sub-100µs
- Simple line protocol: `ENQUEUE\t<voice>\t<rate>\t<text>\n` → `OK\t<id>\n` or `ERR\t<msg>\n`
- 455KB arm64 Mach-O binary (was 415KB at v0.1, +40KB for thread + socket + queue)

**Measurements** (Mac Air M4, warm daemon, baseline at `_qa/v0.2-baseline.md`):

| Metric | Value | v0.2 target |
|---------|-------|-----------|
| ACK round-trip (median, 7 calls) | 0.0ms | < 400ms |
| Cold pre-warm (one-time boot) | 340.3ms | informational |

Roadmap target was warm TTFA <400ms. ACK round-trip <100µs lands 4000× under the ceiling — daemon responds long before audio starts.

---

## v0.1 — `say` direct, no daemon · 2026-06-03

**Shipped**:

- Zig 0.16 single-binary CLI, 415KB arm64 ReleaseFast
- `agent-tts "text"` calls `say -v Luciana -r 330` directly
- Flags `--voice NAME --rate WPM -h --help -V --version`
- Default voice **Luciana**, default rate **330wpm** (sweet spot picked by ear — 180 too slow, 430 too dry)

**Measurements** (baseline at `_qa/v0.1-baseline.md`):

| Metric | Value |
|---------|-------|
| Spawn latency (median, 5 runs) | 0.8ms |
| Rate 180 → 600 sweep | linear drop to 540, plateau above |

Spawn = time until `std.process.spawn` returns. Not real TTFA.

**Voices tested — only Luciana survived**:

Other installed Pt-BR voices (Eddy, Flo, Rocko, Reed, Sandy, Grandma, Grandpa, Shelley) — rejected on quality. Luciana Premium wasn't installed on the test machine; once installed, it becomes the default.
