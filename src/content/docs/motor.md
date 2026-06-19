---
title: TTS engine
description: Motor único — Kokoro-82M (ONNX nativo) voz Dora (pf_dora). Pt-BR neural, offline, sem Python, TTFA < 300ms warm.
---

## TL;DR

**Motor único**: **Kokoro-82M** (ONNX Runtime C API nativo em Zig), voz default **Dora** (`pf_dora`, feminina Pt-BR). Warm synth ~80-150 ms por chunk. Single-binary, sem Python.

**Fallback explícito**: macOS `say` (passado com `--engine say`). Só disponível quando solicitado.

| | Kokoro Dora (default) | macOS `say` (fallback) |
|---|---|---|
| Engine type | Neural (ONNX nativo Zig) | Concatenativa + ANE |
| Pt-BR quality | Feminina neural — única voz feminina Pt-BR OSS | Boa (voz instalada) |
| Warm synth | **~80-150 ms** | spawn 0.8 ms + playback |
| Cold engine load | ~3 s model load ao boot do daemon | 0 |
| Disk extra | 310 MB modelo + ~30 MB ONNX RT | 0 (sistema) |
| License | Apache-2.0 (modelo) + MIT (ONNX RT) + GPL-3.0 (espeak-ng linkado) | Free (sistema) |
| Offline | ✅ | ✅ |

## Decisão (ADR-0001)

Ver [`docs/adr/0001-tts-engine-kokoro-dora.md`](https://github.com/biliboss/ptah) para o estudo completo de alternativas (Kokoro vs Qwen3-TTS vs Chatterbox vs MOSS vs ElevenLabs).

Resumo: Kokoro-82M é o único motor OSS com voz feminina Pt-BR nativa que cabe nas 4 restrições do projeto (local M4, sem Python/pip, TTFA < 300ms warm, OSS). Piper Pt-BR só tem vozes masculinas (faber/cadu/jeff). Aprovada de ouvido por Gabriel + Glaucilene.

## Pipeline técnico

```
texto → preproc (abreviações + cardinais)
      → espeak-ng (IPA, lang=pt-br)
      → vocab tokens (tabela fixa 178 símbolos)
      → [0, *tokens, 0] (int64)
      + style = pf_dora[len(tokens)] (float[256])
      + speed (float[1])
      → ONNX Runtime C API → waveform float32 @ 24000 Hz
      → postfx (ffmpeg, opcional)
      → afplay (macOS nativo)
```

## Parâmetros de síntese

| Flag CLI | MCP param | Efeito | Range |
|---|---|---|---|
| `--speed` | `length_scale` | velocidade (1/speed factor) | 0.1–3.0 |
| `--voice` | `voice` | pack de voz (`pf_dora`, `pm_alex`, `pm_santa`) | string |
| `--tech` | `tech` | glossário tech (siglas + unidades + marcas) | boolean |
| `--postfx` | `postfx` | chain ffmpeg pós-síntese | off/clean/tech/broadcast |

## Tech-report mode (v1.10.8+)

`--tech` / `--profile tech` ativa o glossário em `preproc.zig`:

- Siglas → spelling: `API` → `A P I`, `MCP` → `M C P`, `ONNX` → `ônix`
- Unidades → extenso: `250ms` → `duzentos e cinquenta milissegundos`, `64 MB` → `sessenta e quatro megabytes`
- Marcas → fonética: `Docker` → `dóquer`, `Nginx` → `enginx`, `PostgreSQL` → `pós-ti-grês-quiu-el`
- CamelCase → tokens: `getConditioningLatents` → `get Conditioning Latents`
- Versões/URLs/commits → pronúncia natural

## Tuning por chamada (v1.10.7+)

```bash
ptah "Olá."                                  # default Dora
ptah --speed 1.1 "Mais calma."               # 10% mais lento
ptah --tech "API rodou em 250ms."            # modo tech
ptah --profile tech "Release v1.10.13."      # perfil curado
ptah --engine say "Fallback sistema."        # macOS say
```

### Perfis curados (v1.10.9+)

| Perfil | length_scale | noise_scale | noise_w | Caso de uso |
|---|---|---|---|---|
| **`tech`** (default) | 1.05 | 0.35 | 0.45 | Relatórios técnicos — siglas densas |
| **`stock-tech`** | 0.95 | 0.667 | 0.85 | Mais expressivo, suaviza siglas |
| **`broadcast`** | 1.10 | 0.55 | 0.65 | Podcasts / anúncios |
| **`expressive`** | 1.00 | 0.85 | 1.10 | Máxima variedade prosódica |

## SSML (v1.8+)

```bash
ptah --ssml '<prosody rate="slow">Atenção,</prosody> deploy <emphasis level="strong">concluído</emphasis>.'
ptah --ssml '<phoneme alphabet="ipa" ph="ˌæn.θɹəˈpɪk">Anthropic</phoneme> lançou Claude.'
```

`<phoneme>` passa IPA direto ao espeak-ng (Kokoro path); `say` cai no body text.

## Audio post-processing (v1.10.10+)

Ver [Arquitetura — Post-fx pipeline](/ptah/arquitetura/#post-fx-pipeline-v11010) para chain completa e wiring.

```bash
ptah --postfx tech "Relatório de performance."   # RNNoise + EQ + de-esser + comp
ptah --postfx clean "Texto simples."             # highpass + comp leve
```

Prereq: `brew install ffmpeg` + modelo RNNoise em `~/.cache/ptah/rnnoise/cb.rnnn`.
Sem ffmpeg: fallthrough silencioso para PCM seco.
