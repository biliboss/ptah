---
title: TTS engine
description: Piper Faber + Amy ship as the v1.1 default code-switch pair. macOS say Luciana stays the offline-always fallback. Comparison + decision history.
---

## TL;DR

**v1.1 default**: **libpiper** with **Faber (Pt-BR) + Amy (En-US)** loaded side by side. Warm synth ~92 ms per chunk, multi-piper boot ~620 ms when both voices load. Single-binary, no Python.

**Fallback**: macOS `say -v Luciana`. Works even when piper is not built in. Selected with `--engine say`.

All three voices are offline, free, and ship in the same Zig binary.

| | Piper Faber (default Pt) | Piper Amy (default En, v1.1) | macOS `say` (fallback) |
|---|---|---|---|
| Engine type | Neural (ONNX) | Neural (ONNX) | Concatenative + ANE |
| Pt-BR quality | Top neural | n/a | Solid system voice |
| En-US quality | Mispronounces (legacy) | Top neural | Good (Samantha/Daniel) |
| Warm synth | **~92 ms** | ~92 ms (same ONNX runtime) | spawn 0.8 ms + playback |
| Cold engine load | ~340 ms at daemon boot | +340 ms when added | 0 |
| Disk extra | 63 MB voice + ~34 MB dylibs | 63 MB voice (shared dylibs) | 0 (system) |
| Binary delta | +2 KB Zig + dylib payload | 0 (reuses Pt slot) | 0 |
| Code-switch EN | Routed to Amy via detect.zig | Native | Falls back to Pt say |
| License | GPL-3.0 inherits when linked | GPL-3.0 inherits | Free (system) |

v1.0 mispronounced English terms; v1.1 dispatches each sentence to the matching engine via the heuristic detector in `src/detect.zig`.

## Decision history

Before v0.6 the plan called for `say` Luciana as the v1.0 default and an optional Coqui XTTS-v2 Python sidecar for the neural path. That plan was rejected on 2026-06-03 for two reasons:

- **Pt-only Piper Faber** failed code-switch (rejected).
- **XTTS-v2 via Python sidecar** worked but violated the "only Zig" lifecycle constraint.

The accepted alternative landed in v0.6: link **libpiper** from [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) via `@cImport piper.h`. That made Piper Faber a single-binary engine — no Python, no sidecar. v0.7 then made it the default, swapping `say` to the fallback slot.

## Comparison vs alternatives

Primary criterion is **time-to-first-audio** (TTFA). Secondary criterion is disk size (Mac Air M4 with a small SSD).

| Engine | Extra size | Typical warm TTFA | Pt-BR quality | Cost | Offline |
|---|---|---|---|---|---|
| **Piper Faber (libpiper FFI)** | ~63 MB voice + ~34 MB dylibs | **~91 ms warm** | Top neural Pt-BR | Free (GPL) | Yes |
| **macOS `say` Premium** | 0 in binary, ~200 MB system-side | < 200 ms warm | Good (Luciana/Felipe Premium) | Free | Yes |
| Coqui XTTS-v2 | ~2 GB+ | ~500 ms - 1 s first sentence | Excellent, cloneable | Free | Yes |
| Kokoro | ~80 MB | ~200 ms | Pt-BR limited, EN fallback | Free | Yes |
| ElevenLabs | 0 local | 200-800 ms + network RTT | Excellent | Paid + network | No |

## Why Piper Faber wins as default

1. **Neural quality without Python.** Single Zig binary, no venv to bless.
2. **Resident engine in the daemon.** The ~400 ms cold load is paid once at boot; every subsequent synth is ~90 ms.
3. **zaudio streaming PCM.** No WAV temp file, no `afplay` spawn — playback starts the moment the buffer is ready.
4. **Predictable footprint.** 63 MB voice + 34 MB dylibs, downloaded once via `scripts/fetch-voice.sh` + `scripts/build-libpiper.sh`.

## Why `say` Luciana wins as fallback

1. **Zero binary cost.** The voice lives in `/System/Library/Speech/Voices/`. Keeps the no-piper binary under 1 MB.
2. **Apple Neural Engine.** Luciana Premium is neural under the hood — not pure concatenative.
3. **Always works.** Available on every macOS install. No vendor build, no ONNX, no download.
4. **Stable API.** `say` has existed since Mac OS X 10.3.
5. **Native SSML-like cues**: `[[rate 200]]`, `[[slnc 400]]`, `[[volm 0.8]]`.

## System engine per platform (v1.3)

`agent-tts --engine say` dispatches to the local system TTS via `platform.zig`. Each platform has a different engine behind the same flag — quality varies, Piper Faber stays the recommended default everywhere.

| Platform | System engine | Pt-BR quality | Pre-warm | SSML cues |
|---|---|---|---|---|
| **macOS** | `/usr/bin/say -v Luciana` | Top (Apple Neural Engine) | Yes (~270 ms boot) | `[[slnc N]]`, `[[rate N]]`, `[[volm N]]` |
| **Linux** | `espeak-ng -v pt-br` | Robotic — concatenative diphone | No (no warm cache) | None (`[[slnc N]]` rendered as literal text) |
| **Windows** | `powershell System.Speech` | Decent if a Pt-BR SAPI voice is installed | No | None (rate/voice not threaded through in v1.3) |

The Linux and Windows system engines are **fallbacks** in the same sense `say` is on macOS — they exist so a no-piper build still talks. For quality on Linux, ship `-Dwith-piper=true` + the Faber ONNX voice (the libpiper build script supports both macOS and Linux; Windows untested).

Voice mapping for Linux: `tts.zig` translates the four macOS Pt-BR voice names (`Luciana`, `Luciana (Premium)`, `Felipe`, `Felipe (Premium)`) to espeak-ng's `pt-br` language code so a stock `agent-tts "texto"` from a config written on a Mac still works on Linux without `--voice`. Unrecognised voices pass through verbatim — espeak-ng accepts language codes (`pt-br`), variant codes (`mb-br1`), and full names.

## Why the others lose for v1.0

### Coqui XTTS-v2

Excellent quality, but 2 GB+ breaks the SSD goal and the "only Zig" constraint. ONNX export is not production-stable yet (see [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014)). Revisit when ONNX multilingual stabilizes — that is the v1.1 path.

### Kokoro

Pt-BR is not a primary target. EN fallback has an accent. Rejected.

### ElevenLabs

Network-dependent latency wrecks the KPI. Per-message cost kills casual agent use. Offline-only is non-negotiable. Rejected.

## Voice setup

`Luciana (Premium)`. Install via:

```
System Settings → Accessibility → Spoken Content
→ System Voice → Manage Voices
→ Portuguese (Brazil) → Luciana (Premium) → Download
```

The daemon detects it on first run. If missing, it prints the exact path above and falls back to the default system voice.

Masculine alternative: `Felipe (Premium)`. Same quality.

Piper Faber model is downloaded once by `scripts/fetch-voice.sh` to `~/.cache/agent-tts/voices/pt_BR-faber-medium.onnx` (~63 MB).

## Override per call

```bash
agent-tts "Texto."                              # default piper Faber
agent-tts --engine say "Texto."                 # macOS say (fallback)
agent-tts --voice "Felipe (Premium)" "Texto."   # specific say voice
agent-tts --rate 220 "Mais rápido."             # WPM (say only — piper ignores)
```

Persistent config in `~/.config/agent-tts/config.json` planned for v1.1.

## Code-switching EN — closed in v1.1

v1.0 mispronounced `GitHub Actions` as Portuguese phonemes. v1.1 closes that gap by adding a second resident Piper voice — `en_US-amy-medium` — alongside Faber. The daemon's worker chunks each message on sentence boundaries (`. ! ? \n`), detects each sentence's language via a 100-stopword tokenizer (`src/detect.zig`), and synths each chunk on the matching engine. PCM streams concatenate via the same `audio_player.streamS16le` path, so playback gaps stay below human-perceptible threshold for back-to-back same-rate chunks (Faber and Amy are both 22 050 Hz).

Cost: ~340 ms additional cold boot when both voices load (~680 ms total piper init). Per-message TTFA stays in the v0.7 envelope when the input is single-language (one synth call). Mixed messages pay one extra synth per language flip — still under the v1.1 < 150 ms warm budget for typical agent output.

Install the En voice with `./scripts/fetch-voice-en.sh`. The daemon logs `en=off` and falls back to single-voice Pt synth when the file is missing — no crash, no degraded prompt. Force a single voice end-to-end with `agent-tts --lang pt|en "..."`; `auto` (the default) runs the detector per sentence.

The remaining ambition — XTTS-v2-grade multilingual quality from a single ONNX checkpoint — is parked. Piper's per-voice models ship today, work offline, and stay under the disk budget. Single-checkpoint multilingual returns to the table when Coqui's ONNX export stabilizes (see [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014)) or a Piper community checkpoint matches Faber/Amy quality. Tracked in [What's next](/whats-next/).
