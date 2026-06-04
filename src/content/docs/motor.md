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

## Tuning Piper per call (v1.10.7+)

Three Piper inference knobs are exposed per call. They override any daemon-wide `AGENT_TTS_PIPER_*` env var and the voice config defaults:

| Flag | Range | Default | Effect |
|---|---|---|---|
| `--length-scale` | 0.1 – 3.0 | voice default (≈1.0) | <1 = faster; >1 = slower |
| `--noise-scale` | 0 – 2 | voice default (Faber ≈0.667) | Higher = more prosody variation |
| `--noise-w` | 0 – 2 | voice default (Faber ≈0.8) | Higher = more pronunciation variation |

Sentinels: omitting a flag (or passing the sentinel `0` for `--length-scale`, negative for the others on the wire) preserves the env-or-voice default. Mix-and-match freely:

```bash
# Default voice profile
agent-tts "Olá."

# Warm Faber — slightly slower + softer prosody
agent-tts --length-scale 1.05 --noise-scale 0.7 --noise-w 0.9 "Olá calmamente."

# Expressive Faber — more pronunciation variety
agent-tts --noise-w 1.1 "Olá com mais vida."

# Faster reading (matches macOS say rate ≈ 380 wpm)
agent-tts --length-scale 0.9 "Resumo veloz."
```

The daemon logs the resolved knobs on every override:

```
[worker] piper id=42 length_scale=1.050 noise_scale=0.700 noise_w=0.900
[worker] piper id=42 lang=pt synth=98.3ms play=2147.4ms samples=47312
```

Same wire travels through MCP — the `say` tool accepts the three optional numeric arguments, and `synth_voice_test(text, length_scale, noise_scale, noise_w)` is a one-shot A/B helper that echoes the resolved knobs back so Claude Code can record a comparison run.

### Recommended Faber profiles

Validated 2026-06-04 against a 35 s reference utterance:

| Profile | length_scale | noise_scale | noise_w | Use case |
|---|---|---|---|---|
| **Default** | (unset) | (unset) | (unset) | Baseline Faber |
| **Warm** | 1.05 | 0.70 | 0.90 | Reading text aloud, calmer flow |
| **Expressive** | 1.00 | 0.85 | 1.10 | Pitch/announcements, more variety |
| **Fast** | 0.90 | (unset) | (unset) | Snappy status reports |

### SSML interaction

When `--ssml` is set, `<prosody rate>` inside the markup overrides `--length-scale` per scope (the SSML walker computes `length_scale = 1/rate` per chunk). `--noise-scale` and `--noise-w` still apply globally because the walker doesn't touch those knobs.

## Tuning Piper for tech reports (v1.10.8+)

Engineering reports stress Piper's espeak-ng frontend in ways the conversational defaults handle poorly:

- **Short acronyms** (API, MCP, CPU) get phonemized as Pt-BR words ("api" rhyming with "tapi") rather than spelled letters
- **Unit symbols** (MB, ms, Hz, kHz) sound like the abbreviated letters instead of the spelled-out words
- **Mixed-language brands** (ONNX, JSON, GitHub) hit espeak-ng's English fallback inconsistently

`--profile tech` (or `--tech`) bundles the empirical sweet spot:

```bash
agent-tts --profile tech "API e MCP rodam em CPU. 250 ms warm synth, 64 MB ONNX."
```

Equivalent to:

```bash
agent-tts \
  --tech \
  --length-scale 0.95 \
  --noise-scale 0.667 \
  --noise-w 0.85 \
  --sentence-pause 500 \
  "API e MCP rodam em CPU. 250 ms warm synth, 64 MB ONNX."
```

### Glossary excerpt

`processTech` runs before the rest of the v0.5 preproc so cardinal expansion sees already-spelled acronyms:

| Source | Replacement | Notes |
|---|---|---|
| `API` | `A P I` | Case-insensitive |
| `MCP` | `M C P` | Case-insensitive |
| `CPU` `GPU` `TTS` `SQL` `URL` `DNS` `SSH` `IDE` `LLM` `CSS` `XML` `SDK` `CLI` | spelled | 3-letter common tech |
| `MB` `KB` `GB` `TB` | `megabytes` etc | Word-boundary aware (MBPS not matched) |
| `ms` `µs` `ns` `Hz` `kHz` | `milissegundos`, `microssegundos`, `nanossegundos`, `hertz`, `kilohertz` | Longest-first sorting beats partial matches |
| `ONNX` | `ônix` | 4+ letter brand → phonetic |
| `JSON` `YAML` `HTML` | phonetic | Case-insensitive |
| `XTTS v2` | `X T T S vê dois` | Multi-word source |
| `GitHub` `ChatGPT` `SwiftUI` `libpiper` | branded phonetic | Mixed-case exact match |
| `Anthropic` `Cursor` `Cline` `Piper` `Faber` | verbatim | Already pronounceable Pt-BR |

Word-boundary check matches `expandAbbreviations` — a glossary src never matches mid-word (so "Bitmap" stays untouched even though "MAP" isn't in the table).

### Pause math

Defaults (v0.5 path):

| Punctuation | `[[slnc N]]` ms |
|---|---|
| `,` | 150 |
| `.` `!` `?` | 400 |
| `\n` | 600 |

Tech profile bumps the sentence break to 500 ms (`--sentence-pause 500`). Use `--comma-pause` / `--sentence-pause` / `--newline-pause` to override any of them per call without recompiling. `0` = use the v0.5 default.

For piper, the cadence comes from `length_scale` (slower model = longer phonemes between sentences) — the `--sentence-pause` flag affects the `say` engine and the `[[slnc]]` directives the preproc emits; piper's continuous PCM gets the engineering rhythm from `length_scale=0.95` plus the natural break the streaming pipeline already inserts between chunks.

### A/B helpers

| Tool | What it does |
|---|---|
| `synth_voice_test(text, length_scale, noise_scale, noise_w, tech?, *_pause_ms?, speaker_id?)` | Single shot. Echoes the resolved knobs in the response |
| `voice_knob_search(text, variants[], max_variants?)` | N variants in one MCP round-trip. Returns `{id, comment, knobs}` per variant. Cap 16 |

The `voice_knob_search` tool replaces the 16-step "tools/call → wait → tools/call" loop with one call so Claude Code can scan a knob hyperplane in seconds.

### Multi-speaker selector

`--speaker-id N` (or the `speaker_id` MCP param) maps to `piper_synthesize_options.speaker_id`. Faber + Amy are single-speaker (no effect). Multi-speaker VCTK exports vary the timbre by integer index — use this with custom Piper models, not with the bundled voices.

## Faber tech-narration profile (v1.10.9)

v1.10.9 replaces the v1.10.8 tech knobs with research-anchored defaults sourced from [`_qa/v1.10.9-research-prompt-output.md`](https://github.com/biliboss/agent-tts/blob/main/_qa/v1.10.9-research-prompt-output.md) — an external LLM distillation of Faber-medium / MCV / VITS-15M evidence:

| Knob | v1.10.8 tech | v1.10.9 tech | Why |
|---|---|---|---|
| `length_scale` | 0.95 | **1.05** | MCV fast read-speech; +5% recovers intelligibility on symbol strings |
| `noise_scale` | 0.667 | **0.35** | 0.30–0.40 range avoids mid-sentence pitch drift |
| `noise_w` | 0.85 | **0.45** | Consistent phoneme durations on acronym/identifier-dense input |
| `sentence_pause_ms` | 500 | 500 | Unchanged |

**Counter-argument** (flagged by the research note): the v1.10.8 numbers (`noise=0.667`, `noise_w=0.85`) sound less robotic on prose-heavy narration even if they smear acronyms. If you prefer expressiveness over crispness, A/B via the new `tech_profile_search` MCP tool (`stock-tech` variant replays the v1.10.8 knobs) or pass explicit `--length-scale` / `--noise-scale` / `--noise-w` to override.

v1.10.9 also rewrites the tech preproc pipeline. The new order, exposed as `preproc.techPipeline(arena, raw, opts)`:

1. **`normalizeIdentifiers`** — rewrites versions (`1.10.8` → `1 ponto 10 ponto 8`), commit hashes (`bdd352e` → `commit bê dê dê três cinco dois é`), URLs (`https://github.com/biliboss/agent-tts` → `github ponto com barra biliboss barra agent-tts`), file paths (`~/.cache/agent-tts/voices/` → `pasta voices`), and hex literals (`0xFF` → `zero-x F F`).
2. **`expandTechGlossary` (pass 1)** — applies the expanded glossary on the normalized output.
3. **`splitCamelCase`** — inserts spaces at camel boundaries with three rules: lower/digit → Upper, Upper → Upper-followed-by-lower (`SQLite` → `SQ Lite`), Upper → digit (`ChatGPT5` → `Chat GPT 5`). UTF-8 continuation bytes never trigger a split so accented Pt-BR words stay intact.
4. **`expandTechGlossary` (pass 2)** — runs again so glossary entries inside the split output (`agentTTSMenubar` → `agent TTS Menubar` → glossary catches `TTS`) still resolve.
5. **`expandAbbreviations`** — v0.5 abbreviation expansion (Sr./Dr./etc.).
6. **`expandNumbers`** — v0.5 Pt-BR cardinal expansion (the version normalizer leaves bare digits behind precisely so this stage spells them).
7. Pauses stage runs OUTSIDE `techPipeline` so `processTech` and `processTechWithPauses` can compose differently.

**Glossary expansion** (v1.10.9 additions):

| Group | New entries |
|---|---|
| Acronyms | HTTPS, HTTP, SSH, TCP, UDP, YAML (Pt-BR `iêimel`), CSV, XML, PDF, IDE, CI-CD, ORM, EOF, UUID, NATS |
| Units | fps (`quadros por segundo`), dB (`decibéis`), px (`pixels`), TB (`terabytes`), bps, Mbps, Gbps |
| Brands | Docker (`dóquer`), Nginx (`enginx`), PostgreSQL (`pós-ti-grês-quiu-el`), SQLite (`es-quiu-lai-ti`), SurrealDB (`surreal D B`), FastAPI (`fast A P I`), Pydantic (`paidântic`), Zsh (`zi shell`), Homebrew (`home-briu`) |

Glossary lookup is still longest-first (HTTPS before HTTP, Mbps before bps) so partial matches never steal prefixes.

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
