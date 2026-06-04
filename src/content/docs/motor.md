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

## Cloned voices (v1.4)

v1.4 adds a **third engine**: `cloned`. Selected automatically when `--voice <slug>` resolves to a directory under `~/.cache/agent-tts/voices/<slug>/` produced by `agent-tts voice clone`.

```bash
agent-tts voice clone --sample me-reading.wav --name gabriel
agent-tts --voice gabriel "Deploy concluído."
```

**The cloned engine is not pure Zig.** Coqui XTTS-v2 (the only credible local Pt-BR cloner) is a 2 GB PyTorch model with no production-stable ONNX export today. Reimplementing XTTS in Zig is not on the table — and embedding the model in a Zig binary breaks the SSD goal anyway.

So v1.4 **relaxes the "only Zig" lifecycle constraint, but only for the cloned engine**. Faber + say still work without Python:

| Engine | Runtime | Python required? |
|---|---|---|
| `say` (Luciana) | macOS system | no |
| `piper` (Faber) | libpiper FFI (Zig binary) | no |
| `cloned` (custom) | Python sidecar via `std.process.Child` | **yes** |

**Process line is the licensing wall.** Coqui TTS is MPL-2.0. The sidecar runs as a separate process spawned from `daemon.zig::synthClonedViaSidecar`. The parent Zig binary stays dual MIT/Apache — no MPL code is linked or distributed inside `agent-tts`.

**Sidecar protocol** (kept boring):

```
voice_synth.py --embedding <path.npz> --rate 22050 [--lang pt]
  ← text on stdin
  → raw s16le mono PCM on stdout at the requested rate
```

The daemon drains stdout into a buffer, feeds it to the same `AudioPlayer.streamS16le` path Faber uses. Fallback chain on sidecar failure: piper Faber when loaded, else `say` Luciana.

**Why this isn't the default.** Cold startup of XTTS-v2 on Apple Silicon CPU is ~6-10s and warm first-sample is ~500-900ms — pessimistic vs Faber's 91ms. Cloned is opt-in for personal voice, not the snappy default.

See [Changelog v1.4](/agent-tts/changelog/#v14--voice-cloning--2026-06-03) for the install + measurement story.

## Code-switching EN — closed in v1.1

v1.0 mispronounced `GitHub Actions` as Portuguese phonemes. v1.1 closes that gap by adding a second resident Piper voice — `en_US-amy-medium` — alongside Faber. The daemon's worker chunks each message on sentence boundaries (`. ! ? \n`), detects each sentence's language via a 100-stopword tokenizer (`src/detect.zig`), and synths each chunk on the matching engine. PCM streams concatenate via the same `audio_player.streamS16le` path, so playback gaps stay below human-perceptible threshold for back-to-back same-rate chunks (Faber and Amy are both 22 050 Hz).

Cost: ~340 ms additional cold boot when both voices load (~680 ms total piper init). Per-message TTFA stays in the v0.7 envelope when the input is single-language (one synth call). Mixed messages pay one extra synth per language flip — still under the v1.1 < 150 ms warm budget for typical agent output.

Install the En voice with `./scripts/fetch-voice-en.sh`. The daemon logs `en=off` and falls back to single-voice Pt synth when the file is missing — no crash, no degraded prompt. Force a single voice end-to-end with `agent-tts --lang pt|en "..."`; `auto` (the default) runs the detector per sentence.

The remaining ambition — XTTS-v2-grade multilingual quality from a single ONNX checkpoint — is parked. Piper's per-voice models ship today, work offline, and stay under the disk budget. Single-checkpoint multilingual returns to the table when Coqui's ONNX export stabilizes (see [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014)) or a Piper community checkpoint matches Faber/Amy quality. Tracked in [What's next](/agent-tts/whats-next/).

## SSML support per engine — v1.8

agent-tts accepts a W3C SSML 1.1 subset on every engine. Pass `--ssml` on the CLI, or set the `ssml: true` argument on the MCP `say` tool, and the daemon parses the input via `src/ssml.zig` before dispatching. Engine support varies — honest table:

| Element | macOS `say` | Piper Faber / Amy | Cloned (XTTS-v2) |
|---|---|---|---|
| `<emphasis level=…>` | volume bump + micro-pause via `[[volm]]` + `[[slnc 80]]` | no-op (no ONNX knob) | future — sidecar passes through |
| `<break time=… strength=…>` | `[[slnc <ms>]]` directive | zero-PCM silence frames at native rate | future |
| `<prosody rate=…>` | `[[rate <wpm>]]` (`330 × rate`) | libpiper `length_scale = 1 / rate` per call | future |
| `<prosody pitch=±st>` | `[[pbas <n>]]` (`47 + 3·semitones`) | no-op | future |
| `<prosody volume=…>` | `[[volm <0..2>]]` | no-op (handled in audio mixer if needed) | future |
| `<say-as interpret-as=characters>` | `[[char LTRL]] … [[char NORM]]` | no-op | future |
| Unknown / `<speak>` envelope | passes through as text | passes through as text | passes through as text |

What this buys you:

- **macOS `say` agents inflect today.** Drop a `<prosody rate="slow">` around the punchline; the agent slows down naturally without the `[[…]]` syntax your prompts would otherwise need
- **Piper agents pace.** Length-scale lets Faber/Amy speak slower or faster per scope — useful for narration / educational content. Pitch and emphasis remain Piper gaps until a future model adds the knobs
- **Pure text remains the fast path.** Without `--ssml`, the v0.5 preprocessor still expands cardinals + abbreviations and inserts `[[slnc]]` pauses on punctuation. v1.8 is purely additive

SSML on Piper takes the single-pass synth path (not the v1.2 streaming chunker) because `<prosody>` scopes may cross sentence boundaries. Long SSML inputs trade ~50 ms first-audio improvement for correctness; plain-text inputs keep the streaming win. Parser cost is **below 0.2 µs for a 280-char message** — TTFA budget unchanged.

Example:

```bash
# Slow opening with an emphatic close
agent-tts --ssml \
  '<prosody rate="slow">Atenção,</prosody> a entrega <emphasis level="strong">acabou</emphasis>.<break time="500ms"/> Próximos passos.'
```

The same string sent via MCP:

```json
{"name":"say","arguments":{
  "text":"<prosody rate=\"slow\">Atenção,</prosody> a entrega <emphasis level=\"strong\">acabou</emphasis>.<break time=\"500ms\"/> Próximos passos.",
  "ssml":true
}}
```
