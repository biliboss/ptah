---
adr: 0001
title: Motor TTS = Kokoro nativo, voz Dora (pf_dora) default
status: accepted
date: 2026-06-19
deciders: Gabriel
---

# ADR-0001 — Motor TTS = Kokoro nativo, voz Dora default

## Contexto

Ptah é um CLI Zig de TTS Pt-BR pra **macOS, rodando local/edge** (alvo: MacBook Air 13" M4 — sem fan, sem CUDA, ANE/GPU integrada). Restrições binárias do projeto:

1. **Local/edge** no M4 Air — nada de GPU dedicada nem serving infra.
2. **Embedded, sem Python/pip** — motor nativo Zig + ONNX Runtime C API.
3. **TTFA < 300ms warm** (KPI único).
4. **OSS, sem vendor lock**.

Histórico: o projeto usava `say` (macOS) e depois Piper/Faber. Piper Pt-BR só tem vozes **masculinas** (faber/cadu/jeff/edresson). Avaliamos Kokoro Pt-BR.

## Decisão

**Motor = Kokoro-82M (ONNX) nativo em Zig; voz default = `pf_dora` ("Dora").**

- Kokoro Pt-BR tem 3 vozes: `pf_dora` (fem), `pm_alex`, `pm_santa` (masc). **Dora é a única feminina Pt-BR nativa** entre Piper e Kokoro. Aprovada de ouvido (Gabriel + Glaucilene).
- 82M params, ONNX, **RTF ~0.3 no M4** (folga grande), fonemização via espeak-ng (lang pt-br). Cabe nas 4 restrições.

## Estudo de alternativas (2026-06-19)

Avaliadas contra as 4 restrições acima:

| Modelo | Tam. | Cabe (local M4 / sem-Python-onnx / TTFA / OSS) | Veredito |
|---|---|---|---|
| **Kokoro Dora** | 82M | ✅ todas | **escolhido** |
| Qwen3-TTS | 0.6–1.7B | ❌ 10–20× maior, PyTorch, "97ms" só com serving infra | rejeitado |
| Chatterbox (Resemble) | ~0.5B | ❌ backbone Llama/PyTorch, Pt-BR fraco, sem onnx limpo | rejeitado |
| MOSS / F5 / VibeVoice | grande | ❌ PyTorch research-grade, Pt-BR incerto | rejeitado |
| **KokoClone** | 82M+enc | 🟡 mesmo backbone Kokoro + clonagem zero-shot, mantém perfil Dora; mas Python (clonagem precisaria port) | **parking lot** |
| ElevenLabs / Fun-Realtime / OpenAI / Google | cloud | ❌ quebra OSS+local+TTFA, custo, lock-in | engine "premium online" opcional |

### Por que não "subir o nível"

No M4 Air, o teto de qualidade de modelos grandes/cloud é **inalcançável sem furar a tese** (local, embedded, sem-Python, TTFA). Ganho real acima da Dora só vem de **clonagem** (KokoClone) ou **cloud** — ambos slice opcional, não bloqueiam launch. Kokoro 82M já roda realtime com folga; não precisamos de modelo maior.

## Consequências

- A abstração `Engine` (enum) fica **aberta**: KokoClone (voz custom) e um "premium cloud" opcional plugam depois **sem refatorar**.
- Linkamos ONNX Runtime (MIT) + espeak-ng (**GPL-3.0** → binário distribuído herda GPL quando linka espeak-ng — registrar no shipping).
- Params de tom expostos no CLI: `--speed`, `--voice`, `--blend` (nativos Kokoro); `--gain`/`--pitch` via pós (postfx). Pitch/emoção NÃO são nativos.

## Parking lot

- **KokoClone** — clonagem de voz mantendo perfil Dora (port Python→Zig do voice-encoder).
- **Engine "premium online" opcional** — ElevenLabs/Google via flag, pra conteúdo gravado de qualidade máxima (fora do default local).
