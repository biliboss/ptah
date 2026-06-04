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

See the [Changelog](/agent-tts/changelog/) for measurements + honest scope per version. The next slate (v1.11+) is unscheduled.

Vote, watch, or send a PR at [biliboss/agent-tts](https://github.com/biliboss/agent-tts).

---

## How to influence the order

The next milestone is the one with the loudest signal.

- 👍 [GitHub issues with the `roadmap` label](https://github.com/biliboss/agent-tts/labels/roadmap)
- ⭐ Star the repo — repo traffic guides priority
- 🛠 Send a PR — the changelog will name you

See also: [Roadmap](/agent-tts/roadmap/), [Changelog](/agent-tts/changelog/), [TTS engine](/agent-tts/motor/), [MCP server](/agent-tts/mcp/), [Playground](/agent-tts/playground/), [Menubar UI](/agent-tts/menubar/).
