---
title: Roadmap
description: v0.1 → v1.0 em marcos curtos. Critério por marco amarrado ao KPI.
---

## TL;DR

6 marcos até v1.0. Cada um valida uma hipótese contra o KPI (time-to-first-audio).

| Marco | Foco | Critério de aceite | Alvo |
|-------|------|--------------------|------|
| v0.1 | `say` direto, sem daemon | Voz Pt-BR sai. TTFA medido (baseline cold) | 2026-06-07 |
| v0.2 | Daemon + socket + fila em memória | Segunda chamada usa daemon quente, TTFA < 400ms | 2026-06-14 |
| v0.3 | SQLite WAL, `queue`/`skip`/`clear` | Fila sobrevive crash do daemon | 2026-06-21 |
| v0.4 | launchd auto-start | Boot do Mac → daemon sobe sem login interativo | 2026-06-28 |
| v0.5 | Preprocessor (números, abreviações, pausas) | Texto com número + abrev sai humano | 2026-07-05 |
| v0.6 | libpiper FFI baseline | brew install cmake + build libpiper de OHF-Voice/piper1-gpl, `@cImport piper.h`, link `libpiper.dylib`, struct `PiperEngine` no daemon, voz Faber synth via C API | 2026-07-15 |
| v0.7 | zaudio streaming PCM + engine routing | `--engine say\|piper` no client, daemon roteia. zaudio em vez de afplay/say-inline. TTFA Piper < 1s warm | 2026-07-22 |
| **v1.0** | Universal binary, brew tap | `brew install gabriel/tap/agent-tts` funciona, TTFA `say` quente < 300ms, TTFA piper warm < 1s | 2026-07-29 |

## v1.1+ (não comprometido)

- Voz Pt-BR multilingual ONNX (resolver code-switch EN — depende de XTTS-v2 ONNX export estabilizar, ou alternativa)
- Linux build (Zig cross-compile)
- Config YAML
- Múltiplas filas nomeadas (`--queue notify`, `--queue chatter`)
- Streaming chunk pra texto longo (primeiro chunk antes de pre-processar resto)

## Instalação (planejada)

```bash
# durante dev
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/agent-tts /usr/local/bin/

# launchd auto-start
agent-tts daemon install

# v1.0
brew install gabriel/tap/agent-tts
```

`launchd` plist em `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist`.

## Medição do KPI

Cada marco mede TTFA em 3 cenários e publica em [_qa/] no repo:

1. **Cold** — daemon parado, primeira chamada
2. **Warm** — daemon rodando, voz pré-carregada
3. **Burst** — 5 chamadas em 100ms (mede backpressure)

Método: `dtruss -t write` no PID do `say` capturando primeiro write no audio device. Cross-check com `ffmpeg` gravando saída do alto-falante e detectando primeiro sample > -40dB.

Sem medição publicada, marco não fecha.

## Não fazer

- Não embutir modelo de voz no binary (quebra SSD)
- Não suportar Windows na v1.0
- Não rodar TTS em paralelo (sobreposição = UX ruim)
- Não usar Cocoa/AVSpeechSynthesizer antes de provar que `say` é insuficiente
- Não criar config file antes da v0.5 (YAGNI)
