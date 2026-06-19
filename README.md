# Ptah — Native Pt-BR Text-to-Speech CLI for macOS

> **Offline Brazilian-Portuguese TTS in your terminal.** Kokoro neural engine, **Dora** voice, zero cloud — a fast, native drop-in replacement for macOS `say`. Single Zig binary, persistent daemon, SQLite-backed queue, and a bundled MCP server so AI agents (Claude Code, Cursor) can speak.

[![CI](https://github.com/biliboss/ptah/actions/workflows/ci.yml/badge.svg)](https://github.com/biliboss/ptah/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org)
[![docs](https://img.shields.io/badge/docs-biliboss.github.io%2Fptah-blue)](https://biliboss.github.io/ptah/)

```bash
ptah "Olá, eu sou a Dora."
```

---

## What is Ptah?

**Ptah** speaks Brazilian Portuguese text aloud on macOS, locally and offline, using the **Kokoro** 82M ONNX model with the **Dora** voice (`pf_dora`). Named after the Egyptian creator-god who *speaks the world into being*, Ptah is built for two callers: you at the terminal, and the AI agents that shell out.

- **Native, no Python** — the engine runs ONNX Runtime + espeak-ng straight from Zig. No sidecar, no venv.
- **Single engine, one great voice** — Kokoro Dora, the only native-quality female Pt-BR voice. No fallbacks to maintain.
- **Daemon + queue** — a persistent daemon (launchd) drains a crash-safe SQLite WAL queue; `ptah "…"` returns in ~1 ms.
- **Agent-ready** — a bundled stdio **MCP server** (`mcp__ptah__say`) lets Claude Code / Cursor speak.
- **macOS-only by design** — Apple Silicon, `afplay` playback, zero vendored audio library.

KPI: **time-to-first-audio (TTFA)**. Every choice is justified against it.

## Install

```bash
brew tap biliboss/tap
brew install biliboss/tap/ptah
ptah daemon install     # start the daemon at login
```

Or build from source (macOS arm64, Zig 0.16+):

```bash
git clone https://github.com/biliboss/ptah && cd ptah
bash vendor/README.md   # see: fetch onnxruntime + brew install espeak-ng
bash scripts/fetch-kokoro.sh
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
ptah "Olá, tudo bem?"            # speak (Kokoro Dora)
ptah --speed 1.1 "mais rápido"   # adjust pace
ptah queue                       # list pending + playing
ptah skip | pause | resume       # control playback
ptah history --limit 10          # recent items
ptah daemon                      # run the daemon (foreground)
ptah mcp                         # stdio MCP server for agents
```

## Voice

Ptah ships one voice — **Dora** (`pf_dora`), Kokoro's Brazilian-Portuguese female voice. Tune it with:

- `--speed <0.7..1.5>` — speaking pace.
- `--voice <name>` — Kokoro voice pack (default `pf_dora`).

## MCP — let agents speak

`ptah mcp` exposes a `say` tool over stdio JSON-RPC. Register it once:

```bash
claude mcp add --transport stdio ptah -- $(which ptah) mcp
```

Then your agent can call `mcp__ptah__say` to voice a summary at the right moment.

## Why Ptah

| | Ptah | macOS `say` | Piper (Python) | ElevenLabs |
|---|---|---|---|---|
| Native Pt-BR neural voice | ✅ Kokoro Dora | ⚠️ system voice | ✅ (sidecar) | ✅ |
| Offline | ✅ | ✅ | ✅ | ❌ |
| No Python / no cloud | ✅ | ✅ | ❌ | ❌ |
| Persistent crash-safe queue | ✅ SQLite WAL | ❌ | ❌ | ❌ |
| Round-trip ACK (warm) | **~1 ms** | n/a | n/a | 200–800 ms |
| Bundled MCP server for agents | ✅ | ❌ | ❌ | ❌ |
| Single binary | ✅ | n/a | ❌ venv | ❌ |

## Docs

Full documentation: **[biliboss.github.io/ptah](https://biliboss.github.io/ptah/)** — architecture, the engine, roadmap.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Trunk-only on `main`; tiered local CI via git hooks (`bash scripts/install-hooks.sh`).

## License

Ptah's source is **MIT OR Apache-2.0**. The shipped binary links **espeak-ng** (GPL-3.0-or-later), so a distributed build inherits GPL-3.0-or-later. ONNX Runtime is MIT; Kokoro model + voices are Apache-2.0.
