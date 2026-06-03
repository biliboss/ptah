---
title: Motor TTS
description: Comparativo de motores Pt-BR e por que `say` Premium Luciana ganha na v1.0.
---

## TL;DR

Escolha **v1.0**: `say` Luciana ganha — TTFA + tamanho + Neural Engine nativo. Decisão revisitada na **v1.1+** porque agentes falam Pt-BR com termos em inglês ("GitHub Actions", "Coolify deploy") e `say` monolingual pronuncia errado.

**Plano v1.1+**: motor multilingual via Python sidecar. **XTTS-v2** (Coqui) escolhido por code-switching nativo Pt+En + qualidade neural top. Custa ~3GB no disco e exige sidecar Python (modelo precisa ficar resident). Decisão tomada 2026-06-03 depois de benchmark com Piper Faber (mono Pt, falhou em EN) e XTTS-v2 CLI (qualidade top mas 27s/call no CLI por reload do modelo).

## Comparativo

Critério primário é **time-to-first-audio**. Critério secundário é tamanho no disco (Mac Air M4 com SSD pequeno).

| Motor | Tamanho extra | TTFA típico | Qualidade Pt-BR | Custo | Offline |
|-------|---------------|-------------|------------------|-------|---------|
| **macOS `say` Premium** | 0 no binary, ~200MB no sistema (voz Premium) | **< 200ms** quente | Boa (Luciana/Felipe Premium) | Grátis | Sim |
| Piper (`pt_BR-faber-medium`) | ~63MB voz + ~10MB runtime | ~100ms | OK, robótica | Grátis (MIT) | Sim |
| Kokoro | ~80MB | ~200ms | Pt-BR limitado, fallback EN | Grátis (Apache) | Sim |
| Coqui XTTS-v2 | ~2GB+ | ~500ms-1s primeira frase | Excelente, cloneable | Grátis | Sim |
| ElevenLabs | 0 local | 200-800ms + RTT rede | Excelente | Pago + rede | Não |

## Benchmark 2026-06-03 + decisão v1.1+

Driver da revisão: agentes falam Pt-BR com termos em inglês ("GitHub Actions", "Coolify deploy") e `say` monolingual pronuncia errado. Testado: Piper Faber (mono Pt, Python via uvx) e XTTS-v2 multilingual.

| Engine | Footprint | TTFA real (agent UX) | Code-switch | Veredito |
|--------|-----------|----------------------|-------------|----------|
| say Luciana | 0 | ~50ms (daemon quente) | ruim | mantém na v1.0 |
| Piper Faber via uvx | 250MB | ~650ms | ruim | rejeitado (mono Pt + python dep) |
| XTTS-v2 CLI Python | 3GB | 27s/call (Python reload) | bom | rejeitado (CLI unviável, sidecar Python rejeitado por "only Zig") |

Disco antes: 8.4GB free. XTTS reservou 3GB. Limpeza pós-decisão liberou tudo.

### Plano v1.1+ travado: **libpiper FFI**

Restrição auto-imposta: **only Zig** owns o lifecycle. Sem sidecar Python. Pesquisa em OSS Zig (Ghostty, zml, matklad notes, zaudio):

- **libpiper** (de [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl), 4.3k★, GPL) — única C API limpa, atualizada, com voz Pt-BR. Build via CMake puxa onnxruntime + espeak-ng. `@cImport piper.h` + link `libpiper.dylib`
- **Não existe Zig port** maduro de Piper. Wrapper ONNX Runtime em Zig ([recursiveGecko/onnxruntime.zig](https://github.com/recursiveGecko/onnxruntime.zig), 34★) é incompleto, sem CoreML provider
- **zaudio** ([zig-gamedev/zaudio](https://github.com/zig-gamedev/zaudio), miniaudio wrap) — playback PCM streaming sub-1s TTFA, callback-driven, sem WAV temporário
- **Arquitetura Ghostty-style**: struct `PiperEngine` long-lived, init no daemon boot com `errdefer` pra unwind parcial, deinit no shutdown. Per-utterance `ArenaAllocator` reset entre chamadas. Allocator root = GPA pra debug + leak check
- **Gap aceito**: voz Faber-medium é mono Pt, code-switching EN ainda falha. Resolver depois com voz multilingual ONNX quando disponível (XTTS ONNX export ainda não é produção segundo [Coqui discussion #4014](https://github.com/coqui-ai/TTS/discussions/4014))
- **License**: GPL herda do libpiper. agent-tts vira GPL na v1.1+ se distribuir binário. Aceito.

## Por que `say` Premium ganha

1. **Zero peso no binary**. Voz mora em `/System/Library/Speech/Voices/`. Mantém alvo SSD pequeno
2. **Apple Neural Engine** usado nativamente — Luciana Premium é neural, não concatenativa
3. **TTFA consistente**: daemon faz pre-warm uma vez (`say -v Luciana ""`), próximas chamadas < 200ms
4. **Qualidade Pt-BR aceitável** pra uso interno de agentes — não estamos vendendo audiobook
5. **API estável**: `say` existe desde Mac OS X 10.3, não vai mudar
6. **Suporte nativo a SSML-like**: `[[rate 200]]`, `[[slnc 400]]`, `[[volm 0.8]]`

## Por que os outros perdem na v1.0

### Piper
Bom motor. Voz Pt-BR principal (`faber-medium`) é OK mas robotizada. Vale como fallback offline em Linux ou se Apple algum dia remover `say`. **v1.1+**.

### Kokoro
Pt-BR não é alvo nativo do projeto, faz fallback pra EN com sotaque. Reprovado.

### Coqui XTTS-v2
Qualidade excelente, mas 2GB+ quebra a meta de SSD. TTFA cold acima de 1s. Cabível se um dia a meta mudar pra "clonagem de voz do Gabriel".

### ElevenLabs
Latência dependente de rede destrói o KPI. Custo por mensagem mata uso casual de agente. Reprovado.

## Voz padrão

`Luciana (Premium)`. Usuário instala via:

```
System Settings → Accessibility → Spoken Content
→ System Voice → Manage Voices
→ Portuguese (Brazil) → Luciana (Premium) → Download
```

Daemon detecta na primeira run. Ausente → printa instrução exata + link e cai pra voz default do sistema como degradado.

Alternativa masculina: `Felipe (Premium)`. Mesma qualidade.

## Override por chamada

```bash
agent-tts --voice "Felipe (Premium)" "Texto."
agent-tts --rate 220 "Mais rápido."
```

Config persistente em `~/.config/agent-tts/config.json` (futuro v0.5+).
