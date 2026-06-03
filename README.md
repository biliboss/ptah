# agent-tts

> **Fast Pt-BR TTS CLI for macOS in Zig.** Single binary, persistent daemon, SQLite-backed queue, libpiper neural voice (Faber) by default with `say` Luciana as fallback. Alternative to `say`, `espeak`, Piper Python sidecar, ElevenLabs — but built for the terminal AND for AI agents that shell out.

[![CI](https://github.com/biliboss/agent-tts/actions/workflows/ci.yml/badge.svg)](https://github.com/biliboss/agent-tts/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0 (core) / GPL-3.0 (with piper)](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20%2F%20GPL--3.0-blue.svg)](#license)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org)
[![docs](https://img.shields.io/badge/docs-biliboss.github.io%2Fagent--tts-blue)](https://biliboss.github.io/agent-tts/)

---

## Why agent-tts?

| | agent-tts | macOS `say` | Piper (Python) | espeak-ng | ElevenLabs |
|---|---|---|---|---|---|
| Round-trip ACK (warm) | **<1ms** | n/a | n/a | n/a | 200-800ms network |
| Piper synth warm | **91ms** | n/a | 200-300ms | n/a | n/a |
| Cold daemon boot | **~720ms** | 0 (fork+exec each call) | 1-3s (Python) | 0 | 0 |
| Persistent queue (crash-safe) | ✅ SQLite WAL | ❌ | ❌ | ❌ | ❌ |
| Skip / clear / list | ✅ `queue \| skip \| clear` | ❌ | ❌ | ❌ | n/a |
| Auto-start (launchd) | ✅ `daemon install` | n/a | manual | manual | n/a |
| Pt-BR neural voice | ✅ Faber (Piper) | ✅ Luciana (Premium) | ✅ | ❌ | ✅ |
| Pt-BR text preprocessor | ✅ numbers + abrev + pauses | ❌ | ❌ | partial | ❌ |
| Single binary | ✅ ~975KB | n/a | ❌ Python venv | ✅ | ❌ |
| Offline | ✅ | ✅ | ✅ | ✅ | ❌ |
| JSON output for agents | partial (line proto) | ❌ | ❌ | ❌ | ✅ |

KPI is **time-to-first-audio (TTFA)** — the latency between `agent-tts "..."` and the first audible sample. Every architectural choice is justified against TTFA.

## Install

### Via brew tap (v1.0+)

```bash
brew tap biliboss/tap
brew install biliboss/tap/agent-tts
```

> The tap repo `biliboss/homebrew-tap` is a placeholder until the first
> tarball release lands. Until then, install from source.

### From source

Requires Zig 0.16 (`brew install zig` or zigup).

```bash
git clone https://github.com/biliboss/agent-tts.git
cd agent-tts
zig build -Doptimize=ReleaseFast
cp zig-out/bin/agent-tts /opt/homebrew/bin/   # or /usr/local/bin/ on Intel
```

Universal binary (arm64 + x86_64):

```bash
zig build universal
file zig-out/bin/agent-tts-universal
# Mach-O universal binary with 2 architectures: ...
```

### Auto-start at login

```bash
agent-tts daemon install      # writes ~/Library/LaunchAgents/io.github.biliboss.agent-tts.plist
agent-tts daemon status       # prints launchd load state
agent-tts daemon uninstall    # removes the LaunchAgent
```

### Enable the libpiper engine (default for Pt-BR neural quality)

`say` is the fallback (always works on macOS). For the **Faber** neural voice
you need to build the vendor libpiper.dylib once. See
[`vendor/README.md`](./vendor/README.md) for the recipe; tl;dr:

```bash
./scripts/build-libpiper.sh        # clones + builds vendor/piper1-gpl
./scripts/fetch-voice.sh           # downloads pt_BR-faber-medium.onnx
zig build -Doptimize=ReleaseFast -Dwith-piper=true
cp zig-out/bin/agent-tts /opt/homebrew/bin/
AGENT_TTS_PIPER=1 agent-tts daemon  # or patch the launchd plist (docs)
```

## Quick start

```bash
agent-tts "Olá, build verde em doze segundos."        # piper Faber (default)
agent-tts --engine say "Fallback via Luciana."        # macOS say
agent-tts "Sr. Silva pagou R$ 1578 em 2026."          # preprocessor expands

agent-tts queue                                       # list pending+playing
agent-tts skip                                        # SIGTERM current `say` / cancel piper playback
agent-tts clear                                       # drop pending

agent-tts daemon                                      # foreground daemon
agent-tts daemon install                              # launchd auto-start

agent-tts piper-test "olá" /tmp/x.wav                 # one-shot synth to WAV
agent-tts ttfa-bench --engine piper --warm 5          # measure first-sample latency
```

## How it works

```
┌─────────────┐    UNIX socket    ┌──────────────┐    ┌─────────────┐
│  agent-tts  │ ───ENQUEUE──────▶ │   daemon     │───▶│   `say`     │
│  (client)   │ ◀── OK + id ────  │  (SQLite     │    └─────────────┘
└─────────────┘                   │   WAL fila)  │    ┌─────────────┐
                                  │              │───▶│  libpiper   │
                                  └──────────────┘    │  + zaudio   │
                                                      └─────────────┘
```

- **CLI + daemon same binary.** `agent-tts` without args = client. `agent-tts daemon` = server.
- **IPC**: UNIX stream socket at `~/.cache/agent-tts/sock`, line protocol (`ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n`).
- **Queue**: SQLite WAL at `~/.cache/agent-tts/queue.db`. Survives daemon crash + reboot.
- **Worker**: single thread, drains serially. Never two `say` / piper synths in parallel (UX choice).
- **Pre-warm**: daemon boot runs `say -v Luciana " "` to force-load the voice model. PiperEngine stays resident.
- **Preprocessor**: cardinal numbers 0-9999, abbreviations (Sr./Av./R$/…), `[[slnc N]]` pauses on punctuation. Runs in ~2-5µs per message.

Full architecture + decision rationale at the [docs site](https://biliboss.github.io/agent-tts/).

## Status

| Version | Scope | TTFA | Date |
|---------|-------|------|------|
| v0.1 | `say` direct, no daemon | spawn 0.8ms | 2026-06-03 |
| v0.2 | daemon + socket + in-memory queue | round-trip <0.1ms | 2026-06-03 |
| v0.3 | SQLite WAL queue + `queue|skip|clear` | round-trip 0.1ms | 2026-06-03 |
| v0.4 | launchd `daemon install|uninstall|status` | install ~10ms | 2026-06-03 |
| v0.5 | Pt-BR text preprocessor | 2-5µs/msg | 2026-06-03 |
| v0.6 | libpiper FFI baseline | piper init 397ms | 2026-06-03 |
| v0.7 | zaudio + `--engine say\|piper` routing | piper synth warm 91ms | 2026-06-03 |
| **v1.0** | Universal binary + brew formula stub | say warm <300ms, piper warm <1s | 2026-06-03 |

Per-version measurements live in [`_qa/`](./_qa/). Full changelog: [`src/content/docs/changelog.md`](./src/content/docs/changelog.md).

## Roadmap (v1.1+)

- Code-switch EN ("GitHub Actions") via multilingual ONNX (Faber is mono Pt-BR)
- Linux build (Zig cross-compile already works for x86_64-macos)
- Brew tap publish + signed release tarballs
- Named queues (`--queue notify|chatter`)
- Streaming chunk for long text (first chunk plays before rest is preprocessed)
- launchd plist auto-injects `AGENT_TTS_PIPER=1` when piper is built

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Inner loop:

```bash
zig build                              # debug build
zig build test --summary all           # 27 tests
zig build -Doptimize=ReleaseFast       # release build (~975KB w/ piper)
npm run dev                            # docs site (Astro Starlight)
```

## License

Dual: **MIT OR Apache-2.0** for the agent-tts source code (`src/`).

The optional libpiper integration (`src/piper.zig` + `vendor/piper1-gpl/`) is
**GPL-3.0-or-later** (inherited from upstream Piper). Building with
`-Dwith-piper=true` produces a GPL-licensed binary; building without piper
(the default) produces an MIT/Apache-licensed binary that only uses macOS
`say`.

If you want to embed agent-tts in a closed-source product, build without
piper and use `--engine say`. Full breakdown in [`LICENSE`](./LICENSE).

Voice models (`pt_BR-faber-medium.onnx`) are downloaded from
[rhasspy/piper-voices](https://github.com/rhasspy/piper-voices) at runtime
and carry their own licenses (typically CC-BY-NC). agent-tts does not
redistribute the voice models.

## Acknowledgments

- [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) — libpiper + Faber voice
- [zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio) — Zig binding for miniaudio
- [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) — neural runtime under libpiper
- [withastro/starlight](https://github.com/withastro/starlight) — docs site
