---
title: Arquitetura
description: CLI + daemon single-binary, IPC via UNIX socket, fila SQLite, cadência humana.
---

## TL;DR

Single binary Zig. Dois modos no mesmo executável: client (default) e daemon. Client manda mensagem pra daemon via UNIX socket. Daemon enfileira em SQLite, dreena sequencialmente chamando `say`. Auto-start: se socket morto, client faz fork+exec do daemon antes de retentar.

Cada peça existe pra reduzir **time-to-first-audio (TTFA)**. Justificativa por peça abaixo.

## Diagrama

```
┌─────────────┐    UNIX socket    ┌──────────────┐    pipe    ┌────────┐
│  agent-tts  │ ───────────────▶  │   daemon     │ ─────────▶ │  say   │
│  (client)   │ ◀── ack + id ─── │  (queue)     │  stdin     │ (afpla)│
└─────────────┘                   └──────┬───────┘            └────────┘
                                         │
                                         ▼
                                   ~/.cache/agent-tts/
                                     queue.db (SQLite WAL)
                                     sock (UNIX)
                                     daemon.pid
```

## Peças

### Linguagem: Zig 0.14+

- Binary nativo Apple Silicon, sem runtime/GC
- Latência previsível (sem stop-the-world)
- FFI direto pra Cocoa caso `say` não baste no futuro
- Stripped < 2MB

Pin de versão no `build.zig.zon` — Zig ainda quebra entre minor releases.

### CLI + daemon mesmo binary

Reduz superfície de install. `agent-tts` sem args = client. `agent-tts daemon` = servidor. Detecção por argv[1].

**Auto-start**: client tenta conectar no socket. Falha → `fork()` + `execve(self, "daemon", "--detach")` → retry com backoff 10ms × 5. Primeira chamada cold paga ~500ms; chamadas seguintes < 50ms até o ack.

### IPC: UNIX socket

`~/.cache/agent-tts/sock`. Mais rápido que TCP loopback (sem checksum, sem stack TCP). Protocolo: framing por linha JSON.

```
→ {"op":"enqueue","text":"olá","voice":"Luciana","rate":180}
← {"ok":true,"id":42}
```

Cleanup do socket: daemon registra handler SIGTERM/SIGINT → `unlink(sock)`. Start checa se PID em `daemon.pid` ainda vive antes de assumir socket órfão.

### Fila: SQLite (WAL)

`~/.cache/agent-tts/queue.db`. Sobrevive reboot + crash. WAL mode pra worker dreenar sem bloquear `agent-tts queue` (read-only).

Schema mínimo:

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  voice TEXT,
  rate INTEGER,
  state TEXT NOT NULL DEFAULT 'pending', -- pending|playing|done|skipped
  enqueued_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER
);
```

Worker: 1 goroutine-equivalent (single thread loop). Nunca dois `say` em paralelo — sobreposição é UX ruim. Mutex implícito pela fila single-consumer.

### Drive de áudio: `say` (libexec)

`/usr/bin/say -v "Luciana (Premium)" -r 180`. Texto via stdin. Justificativa completa em [Motor TTS](/motor/).

Pre-warm: daemon roda `say -v Luciana ""` no boot pra forçar load do modelo no Neural Engine. Sem pre-warm, primeira chamada paga ~200-400ms a mais.

### Cadência humana

Default 180 WPM (humano normal Pt-BR ~160-180). Pre-processor em Zig faz:

| Entrada | Saída |
|---------|-------|
| `,` | + `[[slnc 150]]` |
| `.` `!` `?` | + `[[slnc 400]]` |
| `\n` | + `[[slnc 600]]` |
| `Sr.` | `Senhor` |
| `cf.` | `conforme` |
| `123` | `cento e vinte e três` (números cardinais Pt-BR) |

Diretivas `[[slnc N]]` são literais aceitas pelo `say`, milissegundos.

## Layout do código

```
src/
  main.zig          # entry, parse argv, route client|daemon
  client.zig        # connect, enqueue, status
  daemon.zig        # accept loop + worker
  queue.zig         # SQLite wrapper
  tts.zig           # invoca say, gerencia processo, pre-warm
  preproc.zig       # normalização + pausas
  ipc.zig           # protocolo socket (JSON-line)
build.zig
build.zig.zon
```

Flat. Sem subdir até virar problema.

## Gotchas previstos

- `say -v Luciana` falha silenciosamente se a voz não tá instalada. Daemon valida com `say -v '?'` no boot e loga warning explícito
- Socket órfão depois de SIGKILL — start checa PID file antes de assumir
- SQLite sem WAL bloqueia `queue` durante `playing` — sempre WAL
- Zig stdlib ainda mexe na API de child process entre versões; isolar em `tts.zig`
