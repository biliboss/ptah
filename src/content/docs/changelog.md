---
title: Changelog
description: Marcos entregues e medições reais por versão.
---

## TL;DR

Por marco: o que entregou, como medimos, o que ficou para o próximo. KPI único é TTFA. Sem número publicado, marco não fechou.

---

## Benchmark interlúdio · 2026-06-03

Antes de codar v0.3, gastei uma sessão benchmarkando motores alternativos pra resolver code-switching Pt+En. Conclusões em [Motor TTS](/motor/). Resumo:

- Piper Faber via Python — mono Pt, rejeitado
- XTTS-v2 multilingual via Python — 27s/call CLI, sidecar Python rejeitado pela restrição "only Zig"
- Decisão: **libpiper FFI** (de OHF-Voice/piper1-gpl) entra como v0.6-v0.7, traz voz Faber + ONNX runtime nativo via `@cImport`, struct `PiperEngine` owner, zaudio pra streaming PCM
- Code-switching EN fica não-resolvido até v1.1+ (ONNX multilingual maduro)

Limpeza: 3.2GB liberados (XTTS-v2 venv + model + uv cache). Voz `pt_BR-faber-medium.onnx` (63MB) mantida em `~/.cache/agent-tts/voices/` para uso em v0.6+.

---

## v0.4 — launchd auto-start · 2026-06-03

**Entregue**:

- Subcomandos `agent-tts daemon install | uninstall | status`
- LaunchAgent plist em `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist` — daemon sobrevive logout/reboot e wakeup
- Atomic write do plist via `createFileAtomic` + `replace` (kernel só vê velho ou novo, nunca half-written)
- `launchctl bootstrap gui/<uid>` no install (substitui o deprecated `launchctl load`); `bootout` no uninstall
- `KeepAlive` como dict `SuccessfulExit=false` — restart só em crash, exit limpo respeitado
- `HOME` força via `EnvironmentVariables` — launchd não herda confiavelmente, sem isso o socket vai pro lugar errado
- Self-locate via `std.process.executablePath` (Darwin: `_NSGetExecutablePath` + realpath) — argv[0] não basta porque launchd recusa relative paths
- uid lookup via `std.c.getuid()` pra montar `gui/<uid>` domain
- Override de label via env `AGENT_TTS_LAUNCHD_LABEL` — usado pelo dry-run test pra não clobberar install real
- Guards defensivos: install recusa se plist já existe, uninstall recusa se não existe (mensagem explícita pro usuário)
- Binary 481KB arm64 Mach-O ReleaseFast (era 455KB em v0.2, +26KB pelo módulo launchd + uso de `std.process.run`)

**Medições** (Mac Air M4, dry-run com test label, baseline em `_qa/v0.4-baseline.md`):

| Métrica | Valor | Alvo v0.4 |
|---------|-------|-----------|
| Install round-trip (mediana, 3 runs) | ~10ms | < 200ms |
| Uninstall round-trip (mediana, 3 runs) | ~10ms | < 200ms |
| Plist parse (`plutil -lint`) | OK | OK |
| `launchctl list` post-install | PID + label visível | visível |
| `launchctl list` post-uninstall | label ausente | ausente |

Dominado pelo fork+exec do `/bin/launchctl`. Granularidade `/usr/bin/time` em macOS = 10ms; real ≤ 10ms.

**Gaps que viram v0.5**:

- Install não detecta daemon já rodando manualmente (conflita no socket). Workaround: `pkill` antes de install.
- Sem `daemon restart` — usar `uninstall && install`.
- Sem `daemon logs` (tail dos .log).
- Pre-warm continua single-shot na boot do daemon — se launchd ressuscitar várias vezes/dia, paga 340ms cada vez. Monitorar.

**Não fechou nesta versão** (movido):

- SQLite WAL queue + comandos `queue/skip/clear` → ainda v0.3 (paralelo a v0.4)
- Preprocessor de números + pausas → v0.5

---

## v0.2 — daemon + socket + fila in-memory · 2026-06-03

**Entregue**:

- Daemon foreground (`agent-tts daemon`) com socket UNIX em `~/.cache/agent-tts/sock`
- Fila in-memory thread-safe (`std.Io.Mutex` + `std.Io.Condition` + `std.ArrayList`)
- Worker thread única dreina a fila chamando `say` — playback serializado, nunca paralelo
- Pre-warm da voz Luciana no boot do daemon (`say -v Luciana " "`)
- Cliente faz round-trip via socket: ENQUEUE → ACK em sub-100µs
- Protocolo de linha simples: `ENQUEUE\t<voice>\t<rate>\t<text>\n` → `OK\t<id>\n` ou `ERR\t<msg>\n`
- Binary 455KB arm64 Mach-O (era 415KB em v0.1, +40KB pelo thread + socket + queue)

**Medições** (Mac Air M4, daemon quente, baseline em `_qa/v0.2-baseline.md`):

| Métrica | Valor | Alvo v0.2 |
|---------|-------|-----------|
| Round-trip ACK (mediana, 7 calls) | 0.0ms | < 400ms |
| Pre-warm cold (boot único) | 340.3ms | informativo |

Alvo do roadmap era TTFA quente <400ms. Round-trip ACK <100µs sai 4000x abaixo do teto — daemon responde muito antes do áudio começar. TTFA real (primeiro sample audível) ainda precisa dtruss + captura de áudio, fica para v0.3.

**Gaps que viram v0.3**:

- Fila não sobrevive restart do daemon → SQLite WAL
- Sem comandos `agent-tts queue` / `skip` / `clear`
- TTFA real (audio sample) ainda não medido

**Não fechou nesta versão** (movido):

- Auto-start (fork+exec ou launchd) → v0.4
- Preprocessor de pausas + números → v0.5

---

## v0.1 — `say` direto sem daemon · 2026-06-03

**Entregue**:

- CLI Zig 0.16 single-binary, 415KB arm64 ReleaseFast
- `agent-tts "texto"` chama `say -v Luciana -r 330` direto
- Flags `--voice NAME --rate WPM -h --help -V --version`
- Default voice **Luciana**, default rate **330wpm** (sweet spot decidido por ouvido — 180 lento, 430 seco)

**Medições** (baseline em `_qa/v0.1-baseline.md`):

| Métrica | Valor |
|---------|-------|
| Spawn latency (mediana, 5 runs) | 0.8ms |
| Rate 180 → 600 sweep | redução linear até 540, plateau acima |

Spawn = tempo até `std.process.spawn` retornar. Não é TTFA real.

**Vozes testadas — só Luciana sobreviveu**:

Outras vozes Pt-BR instaladas (Eddy, Flo, Rocko, Reed, Sandy, Grandma, Grandpa, Shelley) — reprovadas por qualidade. Luciana Premium não instalada na máquina de teste; quando instalada, vira default.
