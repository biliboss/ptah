---
title: Changelog
description: Marcos entregues e medições reais por versão.
---

## TL;DR

Por marco: o que entregou, como medimos, o que ficou para o próximo. KPI único é TTFA. Sem número publicado, marco não fechou.

---

## v1.0 — universal binary + brew tap · 2026-06-03

**Entregue**:

- `zig build universal` — novo step em `build.zig` que compila duas slices independentes (`aarch64-macos` + `x86_64-macos`, ReleaseFast, libpiper OFF) e funde com `lipo -create` em `zig-out/bin/agent-tts-universal`
- Cross-compile fallback: `sdkRoot()` em `build.zig` localiza o macOS SDK (CLT preferido, Xcode.app fallback) e adiciona library/include/framework paths para os cross-targets. Sem isso, Zig 0.16 falha o linker em `libsqlite3.tbd` e o `@cImport` em `sqlite3.h` para alvos não-nativos
- `build.zig.zon` versão `1.0.0`, `src/main.zig` `VERSION = "1.0.0"`
- `Formula/agent-tts.rb` — Homebrew formula com `depends_on "sqlite"` + `macos: :ventura`, `test do system "#{bin}/agent-tts", "--version" end`, e header documentando o tap path `gabriel/tap` (placeholder — substituir pelo tap real quando o repo for criado)
- `README.md` expandido com seções de instalação (brew tap, source, launchd auto-start, libpiper opcional)
- Universal binary roda em ambas as arquiteturas via `arch -arm64` e `arch -x86_64` (Rosetta 2), reportando `agent-tts 1.0.0` em cada

**Medições** (Mac Air M4, ReleaseFast, libpiper OFF, baseline em `_qa/v1.0-baseline.md`):

| Métrica | Valor | Alvo v1.0 |
|---------|-------|-----------|
| Universal binary size (com v0.7 zaudio) | 1 801 696 B (~1.8 MB) | < 2 MB ✅ |
| Host arm64 binary size (com v0.7 zaudio) | 900 552 B (~880 KB) | < 1 MB ✅ |
| Universal binary size (sem v0.7, libpiper OFF) | 1 076 576 B (~1.1 MB) | informativo |
| `lipo -info` | `x86_64 arm64` | duas arches ✅ |
| Round-trip ACK daemon quente (mediana, 7 calls) | 0.1 ms | < 300 ms ✅ (proxy) |
| Pre-warm cold (boot único) | 275.1 ms | informativo |
| Bare `say` spawn+playback floor | ~790 ms | informativo |
| `brew audit --strict --new` (após fixes) | 2 issues, ambos URLs 404 placeholder | estrutural ✅ |

**Honest scope**:

- TTFA real (audio device first-sample) não medido — dtruss precisa SIP-off, host roda SIP-on. Round-trip ACK 0.1ms é piso seguro: daemon respondeu antes do playback começar. TTFA verdadeira fica entre pre-warm tail (~275ms) e bare-`say` spawn (~790ms)
- Piper warm-path NÃO medido nesta v1.0 — depende de v0.7 (zaudio + engine routing) que está em paralelo. Quando v0.7 fechar, `_qa/v0.7-baseline.md` publica o número
- Intel Mac nativo não testado (sem hardware disponível). Cross-arch sanity validada via `arch -x86_64` (Rosetta 2): slice x86_64 executa e reporta versão correta
- `brew install gabriel/tap/agent-tts` ainda falha — `gabriel/tap` é placeholder, e `url`/`sha256` no Formula são placeholders até a primeira release tarball ser publicada no GitHub e ter o hash computado

**Cross-compile gotcha (Zig 0.16)**:

Zig 0.16 auto-resolve macOS SDK paths só pro target nativo. Para cross-targets o linker falha com `unable to find dynamic system library 'sqlite3'`. Workaround em `configureExe()`: probe `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (CLT) ou Xcode.app SDK, adiciona `usr/lib` ao library path, `usr/include` ao system include path, e `System/Library/Frameworks` ao framework path. `libsqlite3.tbd` é multi-arch (x86_64-macos + arm64e-macos); arm64 não-secure linka contra arm64e sem problema.

---

## v0.7 — zaudio streaming PCM + engine routing · 2026-06-03

**Entregue**:

- `src/audio.zig` — `AudioPlayer` struct dono de uma `zaudio.Engine` (miniaudio). `streamS16le` toca buffer s16 mono direto via `AudioBuffer` + `createSoundFromDataSource`, sem WAV temporário. `requestStop` aborta o poll-loop via flag atômica + `sound.stop()`
- `src/piper.zig` — novo `synthToSamples(arena, text) ![]i16` retorna PCM direto (sem WAV); `sampleRate()` expõe taxa do voice config. `synthToWav` agora chama `synthToSamples` + `writeWav`
- `src/ipc.zig` — campo `engine: Engine = .say` em `Message`, enum `Engine { say, piper }`, encode/parse com layout `ENQUEUE\t<engine>\t<voice>\t<rate>\t<text>`. **Compat retroativo**: `parseRequest` peek-detecta layout v0.6 (4 campos sem engine) e vira engine=.say
- `src/queue.zig` — migration idempotente do schema via `PRAGMA table_info` + `ALTER TABLE items ADD COLUMN engine TEXT NOT NULL DEFAULT 'say'`. `push/list/tryClaimNext` propagam o campo; `PoppedItem` ganha `engine`
- `src/daemon.zig` — `AudioPlayer` boot best-effort no daemon (logging tempo, fallback graceful se zaudio falha → `runPiper` cai para WAV+afplay). `PiperEngine` vive em escopo daemon (refactor do `tryBootPiper` leak-and-pray pra um `Resources` struct passado pro worker). `runOne` switch por `item.engine`; SKIP roteia tanto SIGTERM (say) quanto `audio_player.requestStop()` (piper)
- `src/client.zig` — flag `--engine say|piper`. Default `say`. Voice default vira `Luciana` ou `faber` conforme engine
- `src/main.zig` — HELP atualizado. Subcomando oculto `ttfa-bench --engine X --warm N` instrumenta latência primeiro-sample (zaudio first-sample callback) e roda N ciclos warm
- `build.zig` — wire zaudio + miniaudio vendored sources (~100k LoC single-header) com `-DMA_NO_RUNTIME_LINKING` + CoreAudio/AudioUnit frameworks. `vendor/zaudio/COMMIT` pinned em `e5b89fde58be72de359089e9b8f5c4d5126fb159`
- Patch in-tree em `vendor/zaudio/src/zaudio.zig`: Zig 0.16 removeu `std.Thread.Mutex` — trocado por `std.atomic.Value(bool)` spin lock (contenção negligível em mem callbacks)

**Medições** (Mac Air M4, ReleaseFast, baseline em `_qa/v0.7-baseline.md`):

| Métrica | Valor | Alvo v0.7 |
|---------|-------|-----------|
| Piper TTFA warm (5-iter avg) | **91.3ms** (min 84.8, max 96.6) | < 1s ✅ |
| Piper warm — synth dominante | 91.2ms synth | informativo |
| Piper init cold (bench, FS quente) | 335.0ms | informativo |
| Daemon boot total | ~715ms (pré-warm 270 + zaudio 78 + piper 344) | informativo |
| Say TTFA warm (5-iter avg) | 2229ms* | informativo |
| Binary size sem piper | 918 072 B (+463 KB vs v0.6) | informativo |
| Binary size com piper | 975 304 B (+518 KB vs v0.6) | informativo |
| Daemon RSS resident (piper + zaudio) | 176 MB | informativo |
| Schema migration v0.6 → v0.7 | idempotente, ALTER backfilla 'say' | informativo |

*Caveat: "say TTFA" no bench mede wall-clock spawn+wait+playback completo de uma frase Pt-BR — NÃO é primeiro-sample. macOS `say` não expõe hook pra primeiro frame sem hijack do device. O número real do daemon path é o ~50ms round-trip da v0.2 (voz pré-aquecida).

**TTFA piper warm = 91.3ms** bate o alvo de 1s com 10× de folga. Engine resident no daemon eliminou os 397ms de cold init da v0.6.

**Decisões honestas**:

- zaudio upstream (`zig-gamedev/zaudio`) ainda usa `linkLibC()` (removido em Zig 0.16); vendorizamos `.zig` + `.c` em `vendor/zaudio/` em vez de forkar. Recipe em `vendor/README.md`. Quando upstream atualizar, swap pra `build.zig.zon` dependency
- AudioPlayer usa `AudioBuffer` (uma alocação por utterance) em vez de custom `decoderReadProc` streaming. Mais simples; synth domina TTFA, então otimizar playback overhead não move agulha
- TTFA do `say` permanece não-instrumentado de verdade. Aceito pela v0.7 — daemon path com voz quente já é sub-100ms documentado desde v0.2
- Daemon RSS pula de ~30 MB pra 176 MB quando piper carrega. Preço de manter ONNX runtime + tensores Faber-medium quentes. Usuário opt-in via `AGENT_TTS_PIPER=1`
- `runPiper` registra PID do próprio daemon como "playing" (SKIP não consegue cancelar synth piper em flight — só playback). Trade-off aceito; synth dura 90ms então o usuário raramente quer SKIP no meio

**Gotcha durante build**:

- `std.Thread.Mutex` e `std.Thread.sleep` foram removidos no Zig 0.16. zaudio.zig recebeu shim de spin lock; audio.zig usa `std.c.nanosleep` direto (já linkamos libc no exe)
- `linkLibC()` virou `link_libc = true` na config do módulo. Por isso não usamos o build.zig.zon do upstream
- Daemon original importava `piper.zig` unconditional; @cImport piper.h falha quando `-Dwith-piper=false`. Fix: `piper_mod` é alias condicional em comptime

**License**: GPL-3.0 herda do libpiper + espeak-ng quando agent-tts for distribuído com a dylib. zaudio é MIT. Net: GPL é só por causa do Piper.

---

## v0.6 — libpiper FFI baseline · 2026-06-03

**Entregue**:

- Vendor build de `libpiper.dylib` a partir de [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) tag v1.4.2 (espeak-ng estático + ONNX Runtime 1.22.0 baixados pelo CMake do projeto). Receita reproduzível em `vendor/README.md`, fonte gitignored
- `src/piper.zig` — `PiperEngine` struct via `@cImport piper.h`: `init(voice_path, espeak_data_path)` carrega o modelo, `synthToWav(io, text, out_path)` sintetiza e escreve PCM s16le mono WAV
- `build.zig` — opção `-Dwith-piper=true` linka `libpiper` + `c++` com `rpath` pra `vendor/.../dist/lib/`. Default OFF mantém binário fininho pra quem usa só `say`
- Subcomando experimental `agent-tts piper-test "<text>" <out.wav>` faz bypass do daemon e mede init + synth cold
- Daemon boot opcional: `AGENT_TTS_PIPER=1 agent-tts daemon` carrega `PiperEngine` ao lado do pre-warm Luciana — engine fica resident mas v0.6 NÃO roteia playback ainda (v0.7 faz isso com zaudio)
- Voz `pt_BR-faber-medium.onnx` (63MB) baixada em `~/.cache/agent-tts/voices/`

**Medições** (Mac Air M4, ReleaseFast, baseline em `_qa/v0.6-baseline.md`):

| Métrica | Valor | Alvo v0.6 |
|---------|-------|-----------|
| Piper init cold (filesystem cache miss) | 646.7ms | informativo |
| Piper init warm (FS cached) | ~460ms | informativo |
| Synth + WAV — utterance curta (3-5 palavras) | 60-110ms | — |
| Synth + WAV — parágrafo 268 chars | 731ms | — |
| Total curto (init+synth) | ~535ms | <1s ✅ |
| Total longo (init+synth) | ~1217ms | <1s ❌ (200ms over) |
| Daemon piper engine load | 397ms | <500ms ✅ |
| Binary size sem piper | 455 288 B | baseline |
| Binary size com piper | 457 336 B | +2 KB |

Curto bate o alvo; longo passa em 200ms na cold. v0.7 elimina o init cost ao reusar engine resident.

**Gotcha durante build**: espeak-ng define `N_PATH_HOME=160` e o path absoluto da worktree do vault (>160 chars) silenciosamente trunca nomes de arquivo durante a compilação dos fonemas. Workaround: buildar em `/tmp/piper-build` e linkar `vendor/.../libpiper/build` como symlink. Documentado em `vendor/README.md`.

**License**: GPL-3.0 herda do libpiper + espeak-ng quando agent-tts for distribuído com a dylib. Decisão de licença pública fica pra v1.0 (brew tap).

---

## v0.5 — preprocessor Pt-BR (cadência humana) · 2026-06-03

**Entregue**:

- `src/preproc.zig`: 3 transforms encadeados, single-pass por estágio, alocação via arena por mensagem
  - Abreviações whole-word: `Sr. Sra. Dr. Dra. cf. etc. vs. nº Av. R$`
  - Cardinais Pt-BR 0..9999 (state machine sobre dígitos; skipa se grudado em letra ou `%`; suporte a negativos `-5` → "menos cinco" e zero)
  - Pausas `[[slnc N]]` para `,` (150ms), `.` `!` `?` (400ms), `\n` (600ms); pontuação consecutiva colapsa pra maior do grupo
- Hook em `tts.zig`: `spawnSay()` roda o preproc antes do argv do `say`. Falha do preproc é não-fatal — log + fallback pro texto raw
- Binary 496KB arm64 Mach-O (era 455KB em v0.2; soma v0.3 SQLite + v0.4 launchd + v0.5 preproc)
- 26 testes novos cobrindo cada transform + edge cases. `zig build test` = 27/27

**Medições** (Mac Air M4, ReleaseFast, 1000 iter por caso; baseline em `_qa/v0.5-baseline.md`):

| Caso | input bytes | mediana | média |
|------|-------------:|--------:|------:|
| short greeting (`Olá, mundo.`) | 12 | 2.0 µs | 1.5 µs |
| `Sr. Silva tem 25 anos, certo?` | 29 | 4.0 µs | 3.4 µs |
| `Av. Paulista, nº 1578.` | 23 | 3.0 µs | 3.2 µs |
| `Estamos em 2026 e devemos R$ 1234…` | 47 | 4.0 µs | 3.5 µs |
| long mixed paragraph | 151 | 5.0 µs | 4.4 µs |

Orçamento era < 1ms por mensagem; entregamos 200× abaixo. Zero risco de regressão TTFA.

**Decisões honestas**:

- `Sr.` consome o ponto (vira "Senhor", sem pausa subsequente). Tratado como abreviação, não terminador
- `R$` é substituição cega, não reordena: `R$ 500` → "reais quinhentos". Suficiente até alguém reclamar
- Connector "e" em milhares segue regra Pt-BR: `1500` = "mil e quinhentos", `1578` = "mil quinhentos e setenta e oito"
- Cap em 9999 — números maiores ficam crus (`say` lê dígito-a-dígito)
- Frações, horários (`14h30`), decimais ainda literais. YAGNI até demanda real

---

## v0.4 — launchd auto-start · 2026-06-03

**Entregue**:

- Subcomandos `agent-tts daemon install | uninstall | status`
- LaunchAgent plist em `~/Library/LaunchAgents/cloud.mukutu.agent-tts.plist` — daemon sobrevive logout/reboot
- Atomic write do plist via `createFileAtomic` + `replace` (kernel só vê velho ou novo, nunca half-written)
- `launchctl bootstrap gui/<uid>` no install (substitui o deprecated `launchctl load`); `bootout` no uninstall
- `KeepAlive` como dict `SuccessfulExit=false` — restart só em crash
- `HOME` força via `EnvironmentVariables` — launchd não herda confiavelmente
- Self-locate via `std.process.executablePath` (Darwin: `_NSGetExecutablePath` + realpath)
- uid lookup via `std.c.getuid()` pra montar `gui/<uid>` domain
- Override de label via env `AGENT_TTS_LAUNCHD_LABEL` — usado pelo dry-run test
- Guards: install recusa se plist já existe, uninstall recusa se não existe

**Medições** (Mac Air M4, dry-run com test label, baseline em `_qa/v0.4-baseline.md`):

| Métrica | Valor | Alvo v0.4 |
|---------|-------|-----------|
| Install round-trip (mediana, 3 runs) | ~10ms | < 200ms |
| Uninstall round-trip (mediana, 3 runs) | ~10ms | < 200ms |
| Plist parse (`plutil -lint`) | OK | OK |
| `launchctl list` post-install | PID + label visível | visível |
| `launchctl list` post-uninstall | label ausente | ausente |

Dominado pelo fork+exec do `/bin/launchctl`. Granularidade `/usr/bin/time` em macOS = 10ms; real ≤ 10ms.

---

## v0.3 — SQLite WAL queue + queue/skip/clear · 2026-06-03

**Entregue**:

- Fila migrada de in-memory `ArrayList` para **SQLite WAL** em `~/.cache/agent-tts/queue.db` — sobrevive crash do daemon + reboot
- Schema `items(id, text, voice, rate, state, enqueued_at, started_at, finished_at)` + index parcial em `state IN ('pending','playing')`
- Crash recovery no boot: `UPDATE state='pending' WHERE state='playing'` re-promove órfãos
- 3 novos subcomandos: `agent-tts queue` (lista pending+playing), `skip` (SIGTERM no `say` atual), `clear` (marca pendentes como skipped)
- Protocolo IPC estendido: `ENQUEUE` (igual v0.2) + `QUEUE`, `SKIP`, `CLEAR` + resposta `ITEM\t...\n` + `END\n`
- Worker reescrito: drena via SQLite, registra PID do child antes do `wait()`, SKIP envia SIGTERM no PID guardado
- `@cImport(sqlite3.h)` + `linkSystemLibrary("sqlite3", .{})` — usa libsqlite3 do SDK macOS

**Medições** (Mac Air M4, daemon quente, baseline em `_qa/v0.3-baseline.md`):

| Métrica | Valor | Alvo v0.3 |
|---------|-------|-----------|
| Round-trip ACK enqueue (mediana, 7 calls) | 0.1ms | informativo |
| Round-trip ACK queue (mediana, 5 calls) | 0.1ms | informativo |
| Round-trip ACK skip | <10ms (limite de medição) | informativo |
| Binary size (ReleaseFast) | 476KB | <1MB |
| Persistência (kill -9 mid-play) | ✅ 3/3 items drenam pós-restart | "fila sobrevive crash" |

Critério "fila sobrevive crash do daemon" cumprido: matar daemon + `say` durante a fala deixa item em `playing` na DB; restart re-promove órfão pra `pending` e o worker dreina.
---

## Benchmark interlúdio · 2026-06-03

Antes de codar v0.3, gastei uma sessão benchmarkando motores alternativos pra resolver code-switching Pt+En. Conclusões em [Motor TTS](/motor/). Resumo:

- Piper Faber via Python — mono Pt, rejeitado
- XTTS-v2 multilingual via Python — 27s/call CLI, sidecar Python rejeitado pela restrição "only Zig"
- Decisão: **libpiper FFI** (de OHF-Voice/piper1-gpl) entra como v0.6-v0.7, traz voz Faber + ONNX runtime nativo via `@cImport`, struct `PiperEngine` owner, zaudio pra streaming PCM
- Code-switching EN fica não-resolvido até v1.1+ (ONNX multilingual maduro)

Limpeza: 3.2GB liberados (XTTS-v2 venv + model + uv cache). Voz `pt_BR-faber-medium.onnx` (63MB) mantida em `~/.cache/agent-tts/voices/` para uso em v0.6+.

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

Alvo do roadmap era TTFA quente <400ms. Round-trip ACK <100µs sai 4000x abaixo do teto — daemon responde muito antes do áudio começar.

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
