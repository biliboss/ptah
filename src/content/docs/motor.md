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

## SSML extensions + cadence tricks (v1.10.12+)

Three additions land in v1.10.12 to push *prosody* without retraining the voice. All three are optional and gated.

### `<phoneme alphabet="ipa" ph="…">` — IPA passthrough

Pipe the brand name through piper's espeak-ng phonemizer using `[[ipa]]` Kirshenbaum brackets. `say` strips the tag silently (macOS has no IPA directive) and falls back to the body text.

```bash
agent-tts --ssml '<phoneme alphabet="ipa" ph="ˌæn.θɹəˈpɪk">Anthropic</phoneme> lançou Claude.'
agent-tts --ssml '<phoneme alphabet="ipa" ph="miˈstɾal">Mistral</phoneme> rodou.'
agent-tts --ssml '<phoneme alphabet="ipa" ph="ɡɹɒk">Groq</phoneme> via API.'
agent-tts --ssml '<phoneme alphabet="ipa" ph="oʊˈlɑːmə">Ollama</phoneme> local.'
```

Quality is espeak-ng-bound — verify the brand sounds right before declaring it fixed. Body text inside `<phoneme>` is suppressed on piper (the IPA already represents the spoken form) but kept on `say` (it's the only fallback).

### `<sub alias="…">` — display vs spoken split

Rewrite a displayed identifier to the human-spoken form at preproc time. The alias text replaces the body verbatim on every engine.

```bash
agent-tts --ssml 'Use <sub alias="get conditioning latents">getConditioningLatents</sub> aqui.'
agent-tts --ssml 'Roda no <sub alias="emcêpê">MCP</sub> server.'
```

### Cadence tricks (`--cadence`)

Three independent rules toggled by `CadenceOptions`. `--profile tech` enables all the safe ones; breathing stays opt-in via the env var.

1. **List-end intonation drop.** Sentences with ≥2 commas wrap the last 3 word tokens in `<prosody pitch="-10%" rate="slow">…</prosody>`. Mimics the natural fall at the end of a list.
2. **Bullet-point lift.** Lines starting with `-`, `*`, or `•` wrap the leading label (up to `:` or `—`) in `<prosody pitch="+5%">…</prosody>`. Crisper structure for outline-style speech.
3. **Breathing simulation.** State machine emits `<break time="80ms"/>[[breath]]` every 2-3 sentences. The daemon swaps `[[breath]]` for a pre-loaded WAV when `AGENT_TTS_BREATH_WAV` is set; otherwise the silent break still slows the cadence audibly.

Sox one-liner for the breath WAV:

```bash
sox -n -r 22050 -c 1 ~/.cache/agent-tts/breath.wav synth 0.08 pinknoise vol 0.006
export AGENT_TTS_BREATH_WAV=$HOME/.cache/agent-tts/breath.wav
```

Then:

```bash
agent-tts --profile tech --cadence "A Anthropic, a Mistral, a Groq, quatro LLM labs. Cada uma com sua API."
```

The daemon log will show the SSML walker took over (`piper-ssml id=… tokens=N`) and the resulting prosody/break tags rode into the synth. Cadence persists across daemon restarts via the new `cadence` SQLite column.

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

### Identifier normalization (v1.10.9+)

`normalizeIdentifiers` (in `src/preproc.zig`) is the FIRST pass inside `techPipeline`. It rewrites engineering spans BEFORE the glossary so URLs/versions/commit hashes don't get partial-matched by glossary entries:

| Rule | Input | Output |
|---|---|---|
| **CamelCase split** (via `splitCamelCase` after glossary) | `agentTTSMenubar` | `agent TTS Menubar` |
| | `SQLite` | `SQ Lite` |
| | `ChatGPT5` | `Chat GPT 5` |
| **Version triples** | `1.10.8` | `1 ponto 10 ponto 8` (cardinals spell the integers later) |
| | `v2.4.1` | `v 2 ponto 4 ponto 1` |
| **Commit hashes** (≥4 hex chars, ≥1 letter, truncated at 7) | `bdd352e` | `commit bê dê dê três cinco dois é` |
| | `7c638b0` | `commit sete cê seis três oito bê zero` |
| **URLs** (`http://` / `https://` only) | `https://github.com/biliboss/agent-tts` | `github ponto com barra biliboss barra agent-tts` |
| **File paths** | `~/.cache/agent-tts/voices/pt_BR-faber-medium.onnx` | `pasta pt_BR-faber-medium.onnx` (final component + `pasta` prefix) |
| **Hex literals** | `0xFF` | `zero-x F F` |
| | `0xCAFEBABE` | `zero-x C A F E B A B E` |

Rules are conservative by design:

- CamelCase never splits across UTF-8 continuation bytes — Pt-BR accents stay intact (`coração` is not `cora ção`).
- Commit-hash rule requires at least one letter so `12345678` falls through to the cardinal stage (pure-numeric SHAs would be ambiguous anyway).
- URL rule only catches `http://` / `https://` schemes today. Bare hostnames and other schemes pass through verbatim.
- Hex literals must start with the literal `0x` prefix (case-sensitive on the `x`).

All rules are unit-tested (`tests "normalizeIdentifiers: …"` cover 39 cases in `src/preproc.zig`).

## Profiles (v1.10.10+)

`--profile <name>` (or `profile` on MCP `say` / `tech_profile_search`) bundles a curated knob set. Four bundles ship as of v1.10.10. **The default `tech` profile changed in v1.10.10** — the legacy v1.10.8 numbers moved to `stock-tech` so existing tooling can still ask for them by name.

| Profile | length_scale | noise_scale | noise_w | sentence_pause_ms | comma_pause_ms | cadence | Use case |
|---|---|---|---|---|---|---|---|
| **`tech`** (default) | 1.05 | 0.35 | 0.45 | 500 | — | on | v1.10.9 tight-narrator. Acronym-dense engineering reports |
| **`stock-tech`** | 0.95 | 0.667 | 0.85 | 500 | — | off | Legacy v1.10.8 — more expressive, smears acronyms a bit |
| **`broadcast`** | 1.10 | 0.55 | 0.65 | 650 | 200 | off | Slower, tighter dynamics for podcasts/announcements |
| **`expressive`** | 1.00 | 0.85 | 1.10 | 500 | 160 | off | Maximum variety — narration / pitch decks |

`tech` enables the v1.10.12 cadence pass (list-end pitch drop + bullet lift + breath splice) because the cadence rules are gated on the `tech` flag inside `runPiper`. The other three profiles can still set `--cadence` explicitly to opt in.

Each profile also implies `--postfx tech` is a safe pair (the research-anchored ffmpeg chain); the `--postfx` flag stays independent so an operator can mix-and-match (`--profile expressive --postfx clean` for music-bed VO, for example). See [Audio post-processing](#audio-post-processing-v11010) below for the postfx side.

```bash
agent-tts --profile tech "API e MCP rodam em CPU."           # default tight-narrator
agent-tts --profile stock-tech "API e MCP rodam em CPU."     # legacy v1.10.8 sound
agent-tts --profile broadcast "Boletim das dezesseis horas." # podcast-style
agent-tts --profile expressive "Vocês não vão acreditar…"    # max prosody variety
```

## ONNX runtime + miniaudio quality (v1.10.11+)

v1.10.11 closes the inference-layer half of the same research note that anchored v1.10.9's tech-profile knobs ([`_qa/v1.10.9-research-prompt-output.md`](https://github.com/biliboss/agent-tts/blob/main/_qa/v1.10.9-research-prompt-output.md), "Inference-layer knobs you're missing"). Two wins shipped + one honest gap documented.

### ONNX Runtime threading — single-threaded by default

ONNX Runtime ships with multi-threaded intra-op and inter-op pools sized to the host CPU. On Apple Silicon's P-cores running the Faber-medium VITS (15M params, single graph), every additional thread costs more in barrier sync than it saves in matmul throughput. The research note's recommendation: `intra_op_num_threads=1`, `inter_op_num_threads=1`, `graph_optimization_level=ORT_ENABLE_BASIC` (bit-exact for future cache keying), disable CPU memory arena.

**How we apply it**: `libpiper@v1.4.2` exposes no `OrtSessionOptions` hook in `piper.h` — the public C ABI is `piper_create(model, config, espeak)` with no builder. So v1.10.11 sets the equivalent environment variables before `bootMultiPiper` calls `piper_create`:

```
OMP_NUM_THREADS=1
ORT_NUM_THREADS=1
OMP_THREAD_LIMIT=1
```

`setenv(..., overwrite=0)` means a power user can still override per-launch (`OMP_NUM_THREADS=4 launchctl kickstart ...`) without editing the binary. Daemon boot log surfaces it:

```
[daemon] v1.10.11 onnx env: OMP_NUM_THREADS=1 ORT_NUM_THREADS=1 OMP_THREAD_LIMIT=1 (libpiper exposes no OrtSessionOptions builder)
```

**Honest gap**: `graph_optimization_level` and the memory-arena flag have no env-var equivalents — they require the C++ `Ort::SessionOptions` builder. We'd need to patch `libpiper.cpp` to take a `piper_create_with_options(...)` constructor, then rebuild the vendored libpiper. Deferred until/if upstream piper1-gpl exposes the hook.

### miniaudio resampler LPF — 0 → 8

`zaudio.Engine.Config.pitch_resampling.linear.lpf_order` is the linear-resampler low-pass filter order applied per-Sound when miniaudio resamples between source and device rates. The default in miniaudio is **0** (no LPF — fast but adds aliasing on the resample edge). Faber output is mono 22050 Hz; the typical macOS device runs at 48000 Hz, so every Sound goes through a 22050 → 48000 upsample. LPF order 8 (the documented `MA_MAX_RESAMPLER_LPF_ORDER`) removes the alias content around the Nyquist edge without measurable CPU cost on M-class silicon.

v1.10.11 sets `lpf_order=8` on both `pitch_resampling` (per-Sound) and `resource_manager_resampling` (resource manager, used when sounds load from files — not our path, but kept in sync for consistency). The per-sound path is what catches our `AudioBuffer`-backed sounds (see `miniaudio.c:76587` where `config.resampling = pEngine->pitchResamplingConfig`).

**Gotcha not triggered**: `miniaudio.c:77421` forces `lpfOrder=0` when `pitch != 1.0` because the biquad filter becomes unstable under pitch-shifting. agent-tts doesn't pitch-shift (we run at native rate after the engine upsample), so the LPF stays engaged.

Override per-launch via `AGENT_TTS_AUDIO_LPF_ORDER` (0..8, default 8).

### Gain staging — -3 dBFS headroom

Faber's stressed vowels at end-of-phrase can push peak amplitudes toward 0 dBFS. miniaudio's f32 → device-format converter doesn't apply soft-knee compression; values past ±1.0 hard-clip on the s16 device output. v1.10.11 drops the engine master via `engine.setGainDb(-3.0)` so every sound is attenuated 3 dB before the converter sees the f32 mix.

Side effect: perceived loudness drops ~3 dB. We don't apply auto-makeup-gain because that defeats the purpose (we'd just push the loud frames back to clipping). The right long-term fix is per-utterance peak normalisation — deferred to a v1.11 postfx track.

Override per-launch via `AGENT_TTS_AUDIO_HEADROOM_DB` (default 3.0, expressed as positive dB cut).

### Dither — env knob, no-op today

The research note recommends `ma_dither_mode_triangle` on the s16 device output to spread quantization noise into white instead of correlated tones on quiet PCM tails. miniaudio's `ma_data_converter_config.dither_mode` exposes the value, but `ma_engine_config` does NOT — the engine builds its own converter graph internally and ignores any external dither setting.

v1.10.11 parses `AGENT_TTS_AUDIO_DITHER` (`triangle` default | `none`) and logs the chosen value at boot:

```
[audio] v1.10.11 quality knobs: lpf_order=8 headroom_db=-3.0 dither=triangle (engine cfg)
```

Flipping to `none` produces identical audio today. The env knob is wired so a future patch can replace the engine with a custom `data_callback` over `ma_data_converter` (where we control `dither_mode` directly) without breaking the operator contract. Logged as an honest no-op in the v1.10.11 changelog.
## Audio post-processing (v1.10.10)

v1.10.10 lands the second half of the research note's "Acoustic post-processing" recipe: an opt-in ffmpeg subprocess pipeline that runs between piper's PCM and the zaudio device pump. Four profile chains are selectable via `--postfx P` on the CLI, `postfx` on the MCP `say` / `synth_voice_test` schemas, or per-variant inside `tech_profile_search`.

### Profiles

| Profile | Filter chain | Use case |
|---|---|---|
| `off` (default) | none — PCM goes straight to zaudio | dry path; zero overhead |
| `clean` | `highpass=f=80,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=1dB` | light: clears rumble + tames dynamics; ~30ms warm |
| `tech` | `arnndn=m=cb.rnnn,highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.5,equalizer=f=3500:width_type=o:width=1.5:g=-1.5,equalizer=f=10000:width_type=o:width=2:g=1.8,deesser=i=0.08:m=0.5,acompressor=threshold=-18dB:ratio=2:attack=20:release=200:makeup=2dB` | research chain: RNNoise + warmth (280 Hz) + presence cut (3.5 kHz) + air (10 kHz) + de-esser + 2:1 comp; ~60-90ms warm |
| `broadcast` | `highpass=f=80,equalizer=f=280:width_type=o:width=2:g=2.0,equalizer=f=3000:width_type=o:width=1.5:g=-1.0,deesser=i=0.08:m=0.4,acompressor=threshold=-14dB:ratio=3:attack=15:release=180:makeup=2.5dB` | tighter dynamic range for podcasts/announcements; ~50-70ms warm |

`tech` is the heavy hitter. When RNNoise isn't available the `arnndn=` prefix drops out and the EQ+deesser+comp subset still runs — still a quality lift over dry, just without the neural denoise.

### Install prerequisites

```bash
# ffmpeg — required for any profile other than off
brew install ffmpeg

# RNNoise model — optional but recommended for postfx=tech
mkdir -p ~/.cache/agent-tts/rnnoise
curl -sL https://github.com/GregorR/rnnoise-models/raw/master/conjoined-burgers-2018-08-28/cb.rnnn \
  -o ~/.cache/agent-tts/rnnoise/cb.rnnn
```

`agent-tts` probes for ffmpeg at `$AGENT_TTS_FFMPEG_PATH`, then `/opt/homebrew/bin/ffmpeg`, then `/usr/local/bin/ffmpeg`, then bare `ffmpeg` on PATH. When none exist or the subprocess fails, `postfx=tech` silently falls back to dry PCM and the daemon logs `passthrough (ffmpeg/model unavailable)`. The pipeline is a quality lift, not a hard dependency.

RNNoise model path probes `$AGENT_TTS_POSTFX_RNNN_MODEL` first, then `~/.cache/agent-tts/rnnoise/cb.rnnn`.

### Latency budget

Daemon logs `[worker] id=N chunk=K postfx=tech postfx_ms=X` per chunk. When `postfx_ms` exceeds 100ms the line is suffixed `(>100ms — eating into TTFA)` so A/B sessions surface latency regressions. Typical cost on M-series silicon:

| Cost | First chunk | Subsequent |
|---|---|---|
| `clean` | ~50ms | ~25ms |
| `tech` | ~150-200ms | ~60-90ms |
| `broadcast` | ~80ms | ~50ms |

The streaming pipeline absorbs this because synth-per-chunk is itself ~80-150ms. A single short utterance pays the full first-chunk overhead on first-audio.

### Wiring

The post-fx call sits inside `daemon.zig::playWithPostfx`, between `piper.synth*` (or `cloned`'s sidecar) and `audio_player.streamS16leAppend`. Streaming, single-chunk, and SSML paths all funnel through the same helper. The cloned (XTTS-v2) path also routes through postfx so user-cloned voices benefit from the same chain.

`postfx=off` (the default) returns the PCM slice unchanged with `was_processed=false` — zero allocation, zero subprocess, zero overhead.

### Pipe-deadlock fix + 5 s watchdog (v1.10.13)

v1.10.12 shipped postfx on a serial I/O pump (`writeStreamingAll(stdin) → close → drain stdout → wait()`). When a synth produced more PCM than the kernel pipe buffer (~64 KiB on macOS), ffmpeg's output pipe filled before the daemon drained it; ffmpeg blocked on `write(stdout)`, stopped consuming our input, and `writeStreamingAll` blocked on a full input pipe. The user-visible bug: queue stalled after the first oversize item. Trigger logged as `piper-ssml id=207 synth=52427ms` — ~2.3 MiB of PCM, well past the 64 KiB threshold.

v1.10.13 rewrites `postfx.apply` to spawn three threads around every ffmpeg invocation:

1. **Main thread** writes `samples` into ffmpeg's stdin in chunks, then closes stdin.
2. **Drainer thread** reads ffmpeg's stdout into the result buffer concurrently. Neither pipe ever fills because both are being drained in parallel.
3. **Watchdog thread** sleeps in 50 ms slices for up to `AGENT_TTS_POSTFX_TIMEOUT_MS` (default **5000**). On deadline expiry it `SIGTERM`s ffmpeg, waits 1 s, then `SIGKILL`s if still alive. A `done` atomic retires the watchdog cleanly on healthy completion.

All three threads join before `apply()` returns. On watchdog fire the worker logs `[postfx] watchdog killed ffmpeg after Nms — fallthrough`, gets `was_processed=false`, and plays dry PCM. The queue advances either way because the worker now wraps `runOne` with `defer res.queue.finishPlaying(...)` (v1.10.13 belt-and-braces — see `arquitetura.md` "Logging & observability" for the worker resilience rule).

Validated by setting `AGENT_TTS_FFMPEG_PATH=/tmp/fake-ffmpeg.sh` to a script that exec'd `sleep 999` — watchdog killed it after 2000 ms exactly, dry PCM played, queue continued. See `_qa/v1.10.13-leadtime.md` for the diagnosis.

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
