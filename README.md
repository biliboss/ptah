# ptah

> **Fast Pt-BR TTS CLI for macOS in Zig.** Single binary, persistent daemon, SQLite-backed queue, libpiper neural voice (Faber) by default with `say` Luciana as fallback. Bundled MCP server, menubar app, voice cloning, audio post-fx, tech-report mode, structured logging. Alternative to `say`, `espeak`, Piper Python sidecar, ElevenLabs — but built for the terminal AND for AI agents that shell out.

[![CI](https://github.com/biliboss/ptah/actions/workflows/ci.yml/badge.svg)](https://github.com/biliboss/ptah/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0 (core) / GPL-3.0 (with piper)](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20%2F%20GPL--3.0-blue.svg)](#license)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org)
[![docs](https://img.shields.io/badge/docs-biliboss.github.io%2Fagent--tts-blue)](https://biliboss.github.io/ptah/)

---

## What's new — v1.10.13 (2026-06-04)

- **v1.10.13** — Structured logging (`std.log.scoped` + rotating `~/.cache/ptah/daemon.log`) + worker watchdog that kills hung ffmpeg; `defer finishPlaying` keeps the queue advancing even on synth/postfx error escape; 10 s debug heartbeat.
- **v1.10.12** — SSML `<phoneme alphabet="ipa" ph="…">` + `<sub alias="…">`; cadence pipeline (list-end drop, bullet lift, breathing splice) wired into `--profile tech` via `--cadence`.
- **v1.10.11** — Single-threaded ONNX Runtime via env (`OMP_NUM_THREADS=1` + `ORT_NUM_THREADS=1`) + miniaudio `lpf_order=8` + `-3 dB` master headroom.
- **v1.10.10** — Opt-in ffmpeg audio post-fx (RNNoise + 4-band EQ + de-esser + 2:1 comp) selectable via `--postfx clean|tech|broadcast`. Tight-narrator locks in as the literal `--profile tech` default.
- **v1.10.8 / v1.10.9** — Tech-report mode: acronym + unit + brand glossary (~80 entries), CamelCase splitter, version / commit hash / URL / path / hex normalizer, `tech_profile_search` MCP tool.
- **v1.10.7** — Per-call Piper knobs (`--length-scale`, `--noise-scale`, `--noise-w`) + matching MCP `say` params + `synth_voice_test` tool. No daemon restart for A/B.

Full timeline + measurements: [`src/content/docs/changelog.md`](./src/content/docs/changelog.md) (also live at [biliboss.github.io/ptah/changelog](https://biliboss.github.io/ptah/changelog/)).

---

## Why ptah?

| | ptah | macOS `say` | Piper (Python) | espeak-ng | ElevenLabs |
|---|---|---|---|---|---|
| Round-trip ACK (warm) | **<1ms** | n/a | n/a | n/a | 200-800ms network |
| Piper synth warm | **91ms** | n/a | 200-300ms | n/a | n/a |
| Long-input first audio (streaming) | **~41-52ms** (v1.2) | n/a | full-input wait | n/a | full-input wait |
| Cold daemon boot | **~720ms** | 0 (fork+exec each call) | 1-3s (Python) | 0 | 0 |
| Persistent queue (crash-safe) | ✅ SQLite WAL | ❌ | ❌ | ❌ | ❌ |
| Skip / clear / list | ✅ `queue \| skip \| clear` | ❌ | ❌ | ❌ | n/a |
| Pause / resume / replay / history | ✅ (v1.10.2+) | ❌ | ❌ | ❌ | ❌ |
| Auto-start (launchd / systemd) | ✅ `daemon install` | n/a | manual | manual | n/a |
| Pt-BR neural voice | ✅ Faber (Piper) | ✅ Luciana (Premium) | ✅ | ❌ | ✅ |
| Pt-BR text preprocessor | ✅ numbers + abrev + pauses | ❌ | ❌ | partial | ❌ |
| Tech-report mode | ✅ acronym + unit + brand + CamelCase + URL/hash/version (v1.10.8 / v1.10.9) | ❌ | ❌ | ❌ | ❌ |
| Per-call Piper knobs | ✅ `length_scale` / `noise_scale` / `noise_w` (v1.10.7) | ❌ | env-only | n/a | partial |
| Audio post-fx (RNNoise + EQ + de-esser + comp) | ✅ `--postfx tech` (v1.10.10) | ❌ | ❌ | ❌ | partial |
| SSML 1.1 subset incl. `<phoneme>` / `<sub>` | ✅ (v1.8 / v1.10.12) | ✅ `[[ ]]` only | ❌ | ❌ | ✅ |
| Voice cloning | ✅ XTTS-v2 sidecar (v1.4+) + guided menubar UI (v1.10.3) | ❌ | bring-your-own | ❌ | ✅ (paid) |
| Streaming text input | ✅ `stream` + MCP `say_stream` (v1.7) | ❌ | manual | ❌ | ✅ |
| Menubar app + floating player | ✅ SwiftUI (v1.10 / v1.10.2) | ❌ | ❌ | ❌ | ❌ |
| MCP server bundled | ✅ stdio JSON-RPC, **13 tools** | ❌ | ❌ | ❌ | ❌ |
| Structured logging w/ rotation | ✅ `~/.cache/ptah/daemon.log` (v1.10.13) | ❌ | ❌ | ❌ | n/a |
| Single binary | ✅ ~1 MB | n/a | ❌ Python venv | ✅ | ❌ |
| Offline | ✅ | ✅ | ✅ | ✅ | ❌ |
| JSON output for agents | ✅ MCP JSON-RPC | ❌ | ❌ | ❌ | ✅ |

KPI is **time-to-first-audio (TTFA)** — the latency between `ptah "..."` and the first audible sample. Every architectural choice is justified against TTFA.

## Install

### Via brew tap (v1.0+)

```bash
brew tap biliboss/tap
brew install biliboss/tap/ptah
```

> The tap repo `biliboss/homebrew-tap` is a placeholder until the first
> tarball release lands. Until then, install from source.

### From source

Requires Zig 0.16 (`brew install zig` or zigup).

```bash
git clone https://github.com/biliboss/ptah.git
cd ptah
zig build -Doptimize=ReleaseFast -Dwith-piper=true   # neural Pt-BR voice
cp zig-out/bin/ptah /opt/homebrew/bin/          # or /usr/local/bin/ on Intel

# Optional: symlink scripts/ + .venv-voice/ so the daemon finds the XTTS sidecar
# under launchd (v1.10.5 install convention):
mkdir -p /opt/homebrew/share/ptah
ln -sf "$PWD/scripts"      /opt/homebrew/share/ptah/scripts
ln -sf "$PWD/.venv-voice"  /opt/homebrew/share/ptah/.venv-voice
```

Universal binary (arm64 + x86_64):

```bash
zig build universal
file zig-out/bin/ptah-universal
# Mach-O universal binary with 2 architectures: ...
```

### Auto-start at login

```bash
ptah daemon install      # writes ~/Library/LaunchAgents/io.github.biliboss.ptah.plist
ptah daemon status       # prints launchd load state
ptah daemon uninstall    # removes the LaunchAgent
```

### Enable the libpiper engine (default for Pt-BR neural quality)

`say` is the fallback (always works on macOS). For the **Faber** neural voice
you need to build the vendor libpiper.dylib once. See
[`vendor/README.md`](./vendor/README.md) for the recipe; tl;dr:

```bash
./scripts/build-libpiper.sh        # clones + builds vendor/piper1-gpl
./scripts/fetch-voice.sh           # downloads pt_BR-faber-medium.onnx
zig build -Doptimize=ReleaseFast -Dwith-piper=true
cp zig-out/bin/ptah /opt/homebrew/bin/
PTAH_PIPER=1 ptah daemon  # or patch the launchd plist (docs)
```

## Quick start

```bash
ptah "Olá, build verde em doze segundos."        # piper Faber (default)
ptah --engine say "Fallback via Luciana."        # macOS say
ptah "Sr. Silva pagou R$ 1578 em 2026."          # preprocessor expands

# Tech-report mode + audio post-fx (v1.10.8 / v1.10.9 / v1.10.10)
ptah --profile tech "ptah v1.10.13 roda em CPU. HTTPS 250 ms."
ptah --profile tech --postfx tech "RNNoise + EQ + de-esser cleanup."

# Per-call Piper knobs (v1.10.7)
ptah --length-scale 1.05 --noise-scale 0.35 --noise-w 0.45 "Tight narrator."

# History + pause/resume/replay (v1.10.2)
ptah history --limit 10
ptah pause; ptah resume; ptah replay 42

ptah queue                                       # list pending+playing
ptah skip                                        # SIGTERM current `say` / cancel piper playback
ptah clear                                       # drop pending

ptah daemon                                      # foreground daemon
ptah daemon install                              # launchd auto-start

# MCP server (Claude Code, Cursor, Cline) — 13 tools
ptah mcp                                         # stdio JSON-RPC loop
./scripts/install-mcp.sh                              # wires ~/.claude.json via jq

# Voice cloning (v1.4 + v1.10.3 guided UI)
ptah voice clone --sample /tmp/me.wav --name gabriel
ptah --voice gabriel "Cloned voice."

# Diagnostics
tail -f ~/.cache/ptah/daemon.log                 # structured logs (v1.10.13)
PTAH_LOG_LEVEL=debug PTAH_LOG_SCOPES=worker,postfx ptah daemon
ptah piper-test "olá" /tmp/x.wav                 # one-shot synth to WAV
ptah ttfa-bench --engine piper --warm 5          # measure first-sample latency
```

## How it works

```
┌─────────────┐    UNIX socket    ┌──────────────┐    ┌─────────────┐
│  ptah  │ ───ENQUEUE──────▶ │   daemon     │───▶│   `say`     │
│  (client)   │ ◀── OK + id ────  │  (SQLite     │    └─────────────┘
└─────────────┘                   │   WAL fila)  │    ┌─────────────┐
                                  │              │───▶│  libpiper   │
                                  └──────────────┘    │  + zaudio   │
                                                      └─────────────┘
```

- **CLI + daemon same binary.** `ptah` without args = client. `ptah daemon` = server.
- **IPC**: UNIX stream socket at `~/.cache/ptah/sock`, line protocol (`ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>\n`).
- **Queue**: SQLite WAL at `~/.cache/ptah/queue.db`. Survives daemon crash + reboot.
- **Worker**: single thread, drains serially. Never two `say` / piper synths in parallel (UX choice).
- **Pre-warm**: daemon boot runs `say -v Luciana " "` to force-load the voice model. PiperEngine stays resident.
- **Preprocessor**: cardinal numbers 0-9999, abbreviations (Sr./Av./R$/…), `[[slnc N]]` pauses on punctuation. Runs in ~2-5µs per message.

Full architecture + decision rationale at the [docs site](https://biliboss.github.io/ptah/).

## Status

**Current head: v1.10.13** (2026-06-04). Eighteen base + thirteen v1.10.x patches shipped. KPI is **time-to-first-audio**.

| Version | Scope | Measured | Date |
|---------|-------|----------|------|
| **v0.1 → v0.7** | `say` → daemon → SQLite WAL → launchd → preproc → libpiper → zaudio | piper synth warm **91 ms** | 2026-06-03 |
| **v1.0** | Universal binary + brew formula stub | universal 1.8 MB, host 918 KB | 2026-06-03 |
| **v1.1** | Multilingual: detect.zig + `--lang` + En Piper voice | multi-piper boot 313 ms (Pt only) | 2026-06-03 |
| **v1.2** | Sentence chunking + pipelined synth/playback | long-input first-audio **41-52 ms** | 2026-06-03 |
| **v1.3** | Cross-platform — Linux espeak-ng + systemd + CI matrix | macOS green, Linux green on CI | 2026-06-03 |
| **v1.4** | `voice clone` + `voice list` + XTTS-v2 Python sidecar | surface + 40/40 tests | 2026-06-03 |
| **v1.5** | MCP server: stdio JSON-RPC, 5 tools | binary 993 KB (+115 KB) | 2026-06-03 |
| **v1.6** | Voice cloning ship-it (5 install blockers fixed) | clone 23.4 s, cold synth 26.4 s | 2026-06-03 |
| **v1.7** | Streaming text input (`stream` + `say_stream` MCP) | 166/166 tests | 2026-06-03 |
| **v1.8** | SSML 1.1 subset for `say` + Piper | parse < 0.2 µs / 280 chars | 2026-06-03 |
| **v1.9** | Web playground scaffold (WASM synth deferred) | 4/4 Playwright | 2026-06-03 |
| **v1.10** | Menubar UI (SwiftUI status item) | 911 Swift LOC, 321 KB .app | 2026-06-03 |
| **v1.10.2** | History + pause/resume/replay + floating player | 10 MCP tools total | 2026-06-03 |
| **v1.10.3** | Guided voice clone UI (one-button) | 440 + 170 Swift LOC | 2026-06-03 |
| **v1.10.5** | Daemon + CLI resolve sidecar via absolute path | launchd cwd fix | 2026-06-03 |
| **v1.10.6** | XTTS quality knobs + longer reference window | re-clone live validated | 2026-06-04 |
| **v1.10.7** | Per-call Piper knobs (`--length-scale` / `--noise-scale` / `--noise-w`) | 11 MCP tools | 2026-06-04 |
| **v1.10.8** | Tech-report mode + max knob exposure + `voice_knob_search` | 12 MCP tools | 2026-06-04 |
| **v1.10.9** | Research-anchored `--profile tech` defaults + glossary +30 + normalizer | 13 MCP tools, 307/307 tests | 2026-06-04 |
| **v1.10.10** | Audio post-fx (ffmpeg RNNoise + EQ + de-esser + comp) | warm chunks ~53-70 ms | 2026-06-04 |
| **v1.10.11** | Single-threaded ONNX + miniaudio `lpf_order=8` + `-3 dB` headroom | 3 new env knobs | 2026-06-04 |
| **v1.10.12** | SSML `<phoneme>` / `<sub>` + cadence (list-end drop / bullet lift / breathing) | 10-field wire format | 2026-06-04 |
| **v1.10.13** | Structured logging + worker watchdog + `defer finishPlaying` | rotating `~/.cache/ptah/daemon.log` | 2026-06-04 |

Per-version measurements live in [`_qa/`](./_qa/). Full changelog: [`src/content/docs/changelog.md`](./src/content/docs/changelog.md).

## Roadmap (v1.11+)

Next slate unscheduled — see [What's next](https://biliboss.github.io/ptah/whats-next/) for the policy and how to push priority. Open candidates:

- Code-switch EN ("GitHub Actions") via multilingual ONNX (Faber is mono Pt-BR)
- Brew tap publish + signed release tarballs
- Named queues (`--queue notify|chatter`)
- Real WASM Piper synth wired into the web playground (v1.9 ships the stub)
- launchd plist auto-injects `PTAH_PIPER=1` when piper is built
- Synth-side watchdog (today's watchdog covers postfx only)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Inner loop:

```bash
zig build                                              # debug build
zig build test --summary all                           # full test suite (300+ at v1.10.13)
zig build -Doptimize=ReleaseFast -Dwith-piper=true     # release build (~1 MB w/ piper)
npm run dev                                            # docs site (Astro Starlight)
npm run build                                          # static docs build
```

## License

Dual: **MIT OR Apache-2.0** for the ptah source code (`src/`).

The optional libpiper integration (`src/piper.zig` + `vendor/piper1-gpl/`) is
**GPL-3.0-or-later** (inherited from upstream Piper). Building with
`-Dwith-piper=true` produces a GPL-licensed binary; building without piper
(the default) produces an MIT/Apache-licensed binary that only uses macOS
`say`.

If you want to embed ptah in a closed-source product, build without
piper and use `--engine say`. Full breakdown in [`LICENSE`](./LICENSE).

Voice models (`pt_BR-faber-medium.onnx`) are downloaded from
[rhasspy/piper-voices](https://github.com/rhasspy/piper-voices) at runtime
and carry their own licenses (typically CC-BY-NC). ptah does not
redistribute the voice models.

## Acknowledgments

- [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) — libpiper + Faber voice
- [zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio) — Zig binding for miniaudio
- [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) — neural runtime under libpiper
- [withastro/starlight](https://github.com/withastro/starlight) — docs site
