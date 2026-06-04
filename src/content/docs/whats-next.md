---
title: What's next
description: v1.1 → v1.10.8 all shipped 2026-06-03/04. Next milestones land here when planned.
---

## TL;DR

**The entire v1.6 → v1.10.8 slate shipped on 2026-06-03 / 04**, plus v1.1 → v1.5 earlier the same day. Eighteen base + eight patch milestones, all measured.

- **v1.6 Voice cloning ship-it** — XTTS-v2 sidecar live; first cloned voice; 5 install blockers fixed
- **v1.7 Streaming text input** — `agent-tts stream` + `say_stream` MCP tool + incremental chunker
- **v1.8 SSML & prosody** — `<emphasis>` / `<break>` / `<prosody>` / `<say-as>` for say + piper; parse < 0.2 µs
- **v1.9 Web playground** — Astro widget scaffold; WASM synth deferred to v1.9.1
- **v1.10 Menubar UI** — SwiftUI status item + queue + Skip/Clear + voice picker
- **v1.10.1 Playground externalize + menubar icon + screenshot** — production-safe widget assets + baked AppIcon.icns
- **v1.10.2 History + pause/resume + floating player** — persistent timeline + always-on-top widget; 4 new MCP tools
- **v1.10.3 Guided voice clone UI** — one-button Pt-BR clone window in the menubar app; `--quiet` machine contract on `voice clone`
- **v1.10.4 Clone diagnostic** — staged WAV size logged; "Show WAV in Finder" affordance on failed clones
- **v1.10.5 Daemon sidecar absolute paths** — daemon + CLI probe install roots, fixes launchd-spawn cwd
- **v1.10.6 XTTS quality tuning** — temperature/top_k/top_p/repetition_penalty env knobs; longer reference window for speaker latents
- **v1.10.7 Per-call Piper knobs** — `--length-scale` / `--noise-scale` / `--noise-w` flags + matching MCP `say` params + new `synth_voice_test` tool; 8-field ENQUEUE with optional tune triplet; no daemon restart for A/B
- **v1.10.8 Tech-report mode + max knob exposure** — `--tech` glossary (API → A P I, MB → megabytes, ONNX → ônix), `--*-pause` overrides, `--speaker-id`, `--profile tech` shorthand; 9-field ENQUEUE with extra quintuple; new `voice_knob_search` MCP tool for N-variant scans in one round-trip; 12 MCP tools total
- **v1.10.9 Research-informed tech profile + glossary expansion** — `--profile tech` defaults rebuilt on MCV-anchored research (`length=1.05`, `noise=0.35`, `noise_w=0.45`); glossary grows by ~30 entries (HTTPS/HTTP/TCP/UDP/UUID/NATS + fps/dB/px/TB/Mbps + Docker/Nginx/PostgreSQL/SQLite/SurrealDB); new `splitCamelCase` + `normalizeIdentifiers` rewrite versions, commit hashes, URLs, file paths, hex literals; new `tech_profile_search` MCP tool runs a curated 4-variant matrix; 13 MCP tools total
- **v1.10.11 ONNX session + miniaudio quality knobs** — single-threaded ONNX Runtime via daemon env (`OMP_NUM_THREADS=1` + `ORT_NUM_THREADS=1` + `OMP_THREAD_LIMIT=1`; libpiper@v1.4.2 exposes no `OrtSessionOptions` builder, env is the realistic ship); miniaudio `pitch_resampling.linear.lpf_order=8` (was 0 default) removes 22050→48000 upsample aliasing; engine master `setGainDb(-3.0)` for -3 dBFS headroom on Faber's stressed vowels; 3 new daemon-wide env knobs (`AGENT_TTS_AUDIO_DITHER` / `_LPF_ORDER` / `_HEADROOM_DB`); dither documented as no-op today (engine doesn't expose `dither_mode`)
- **v1.10.10 Audio post-fx pipeline + tight-narrator default** — opt-in ffmpeg subprocess chain (RNNoise + 4-band EQ + de-esser + 2:1 compressor) selectable via `--postfx clean|tech|broadcast`; tight-narrator locked in as the literal `--profile tech` bundle plus three more curated profiles (`stock-tech` brings back v1.10.8 numbers, `broadcast` & `expressive` cover the rest of the knob space); new `postfx.zig` module + 10-field ENQUEUE with optional postfx tag + `postfx TEXT` column; `tech_profile_search` doubled to a 4×2 = 8 (knob × postfx) matrix so one MCP call A/Bs both dimensions; daemon logs `postfx=tech postfx_ms=63.5` per chunk with `>100ms — eating into TTFA` warnings; ffmpeg + RNNoise model are best-effort — missing tools fall back to dry PCM silently
- **v1.10.12 SSML phoneme/sub + cadence tricks** — `<phoneme alphabet="ipa" ph="…">` so agents force IPA pronunciation on brand names (Anthropic, Mistral, Groq, Ollama) via piper's espeak-ng `[[ipa]]` brackets; `<sub alias="…">` rewrites code identifiers like `getConditioningLatents` to "get conditioning latents"; `applyCadenceTricks` wraps the last 3 words of 3+-item enumerations with `<prosody pitch="-10%" rate="slow">`, lifts bullet labels with `<prosody pitch="+5%">`, splices an 80ms pink-noise breath every 2-3 sentences when `AGENT_TTS_BREATH_WAV` is set; `--cadence` CLI + `cadence` MCP arg + `cadence` SQLite column; 10-field wire format
- **v1.10.13 Structured logging + worker watchdog** — new `log.zig` module wired to `std.options.logFn`; every `std.log.scoped(.daemon|.worker|.audio|.postfx|.mcp)` call writes ISO 8601 lines to BOTH stderr (launchd compat) and a rotating file at `~/.cache/agent-tts/daemon.log` (3 backups, 10 MiB cap); runtime knobs `AGENT_TTS_LOG_LEVEL` / `_SCOPES` / `_PATH` / `_MAX_BYTES` filter without rebuild; diagnosed the v1.10.12 stall — postfx `apply()` did serial stdin write + stdout drain, so any PCM > 64 KiB kernel-pipe-buffer deadlocked when ffmpeg's own output pipe filled; fix: drain thread runs concurrently with the write, plus a watchdog thread `SIGTERM`s the subprocess after `AGENT_TTS_POSTFX_TIMEOUT_MS` (default 5000); `workerLoop` gained `defer finishPlaying` so the row flips to `done` even on a panicking sub-call; 10 s debug heartbeat proves the worker thread is alive

See the [Changelog](/agent-tts/changelog/) for measurements + honest scope per version. The next slate (v1.11+) is unscheduled.

Vote, watch, or send a PR at [biliboss/agent-tts](https://github.com/biliboss/agent-tts).

---

## How to influence the order

The next milestone is the one with the loudest signal.

- 👍 [GitHub issues with the `roadmap` label](https://github.com/biliboss/agent-tts/labels/roadmap)
- ⭐ Star the repo — repo traffic guides priority
- 🛠 Send a PR — the changelog will name you

See also: [Roadmap](/agent-tts/roadmap/), [Changelog](/agent-tts/changelog/), [TTS engine](/agent-tts/motor/), [MCP server](/agent-tts/mcp/), [Playground](/agent-tts/playground/), [Menubar UI](/agent-tts/menubar/).
