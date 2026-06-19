# Ptah — Motor Kokoro nativo (Zig + ONNX Runtime C API, sem Python)

Spec de implementação do engine `kokoro` (voz default **Dora**, `pf_dora`), embedded,
self-contained no bundle macOS. Referência canônica: **sherpa-onnx** (C++, suporta Kokoro v1.0).
Validação do port: `docs/kokoro-reference-synth.py` (Python que produz o áudio de referência).

## Pipeline

```
texto → espeak-ng (IPA, lang=pt-br) → tokens (vocab 178) → [0, *tokens, 0] (int64)
      + style = voices_dora[len(tokens)]  (float[256])
      + speed (float[1])
      → ONNX Run → waveform float32 @ 24000 Hz → PCM → audio
```

## Modelo ONNX (assets/kokoro-v1.0.onnx)

| input | tipo | shape |
|---|---|---|
| `input_ids` | int64 | [1, L]  (L = nº tokens + 2) |
| `style` | float | [1, 256] |
| `speed` | **float** | [1]  (nosso modelo = float, confirmado via inspect; alguns exports usam int32) |
| output `waveform` | float | [1, N] @ 24000 Hz |

## Tokenização

- **Vocab** = tabela fixa de 178 símbolos (`hexgrad/Kokoro-82M/config.json` campo `vocab`). Portar como mapa estático Zig (codepoint UTF-8 → id). Tabela completa no relatório de pesquisa (memory + abaixo).
- **BOS/EOS = id 0**: `input_ids = [0, *token_ids, 0]`.
- **Style row**: `style = voices[sid][len]` onde `len` = nº de tokens IPA **sem** os dois zeros. voices.bin shape `(speakers, 510, 256)`; pf_dora isolado = `(510,256)`, usar `dora[len]`. (Idêntico ao experimento Python ✓.)

## espeak-ng (fonemização)

```c
espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, "<dir pai de espeak-ng-data>", 0); // sem áudio
espeak_SetVoiceByName("pt-br");
const char *ipa = espeak_TextToPhonemes(&textptr, 1 /*UTF8*/, 0x02 /*IPA*/); // loop até textptr==NULL
```
Gotchas: iterar por **codepoints UTF-8** pro lookup no vocab; pular símbolos não-mapeados;
espeak tem mutex global (não thread-safe — proteger). Misaki usa `--ipa=3` (IPA|TIE) — casar versão do `espeak-ng-data`.

## ONNX Runtime C API (ordem)

`OrtGetApiBase()->GetApi(ORT_API_VERSION)` → `CreateEnv` → `CreateSessionOptions`
(`SetIntraOpNumThreads`) → `CreateSession(model)` → `CreateMemoryInfo("Cpu")`
→ por inferência: `CreateTensorWithDataAsOrtValue` ×3 → `Run` → `GetTensorMutableData` → release tudo.
**CoreML EP não compensa** (shapes dinâmicos recompilam subgraph); CPU é igual/melhor pra utterance curta.

## Zig ↔ C API (gotchas confirmados)

- `OrtApi` é struct de **function pointers opcionais** → chamar SEMPRE com `.?`: `ort.CreateEnv.?(...)`.
- `OrtStatus` = ponteiro opaco, **NULL = sucesso**. Helper `checkOrt` + `ReleaseStatus`.
- paths null-terminated (`[:0]const u8`, usar `.ptr`).
- data tensor → `@ptrCast(slice.ptr)`; saída → `@alignCast(@ptrCast(raw))`.
- nomes de Run: arrays `[_][*:0]const u8{...}`, passar `@ptrCast(&names[0])`.

## Linkagem (build.zig)

onnxruntime + espeak-ng JÁ vendorizados pelo Piper:
- header: `vendor/piper1-gpl/libpiper/lib/onnxruntime-osx-arm64-1.22.0/include/onnxruntime_c_api.h`
- dylib:  `…/lib/libonnxruntime.1.22.0.dylib`
- espeak-ng: build interno do piper (libespeak-ng + speak_lib.h) ou brew `/opt/homebrew/lib/libespeak-ng.1.dylib`
Flag de build: `-Dwith-kokoro=true`. `@embedFile` do modelo 310M = NÃO (binário gigante). Modelo via path relativo ao exe (decisão: **bundle ao lado**).

## Empacotamento (bundle ao lado — decisão Gabriel)

```
ptah.app/Contents/
  MacOS/ptah
  lib/libonnxruntime.dylib   libespeak-ng.dylib   (install_name_tool @executable_path/../lib)
  Resources/kokoro-v1.0.onnx  voices/pf_dora.bin  espeak-ng-data/
```
Binário Zig fica pequeno (KPI <2MB). `pf_dora.bin` pode ser commitado (Apache-2.0). Modelo via `scripts/fetch-kokoro.sh`.

## Parâmetros de tom expostos no CLI

| flag | efeito | nativo? |
|---|---|---|
| `--speed <0.7..1.5>` | duração (1/length_scale) | sim |
| `--voice <pf_dora\|pm_alex\|pm_santa>` | style pack | sim |
| `--blend <voz:ratio,...>` | interpolação linear de 256-d entre packs | sim (montar style misturado) |
| `--gain <db>` | pós (postfx.zig) | pós |
| `--pitch <semitons>` | **não-nativo** → rubberband/sox pós (postfx) | pós |

Kokoro NÃO tem pitch/emoção nativos. Pitch só via pós-processamento.

## Wiring no projeto

1. `src/kokoro.zig` — engine (cImport onnx+espeak, vocab estático, infer).
2. `src/ipc.zig` — `Engine` enum: add `.kokoro`; `fromStr` aceita `kokoro`; **default = .kokoro**.
3. `src/daemon.zig` — rota engine→kokoro (sessão ONNX residente p/ amortizar load ~3s; TTFA pós-warm).
4. `src/client.zig` / `src/main.zig` — `--engine kokoro` default + flags de tom; help.
5. `build.zig` — link onnx+espeak, `-Dwith-kokoro`.
6. Bundle + `scripts/fetch-kokoro.sh` + docs/landing rename agent-tts→ptah.

## KPI

TTFA <300ms warm: sessão ONNX residente no daemon (load uma vez). Inferência RTF ~0.3 no M-series (medido).
Stream o primeiro chunk assim que sair (Kokoro emite waveform inteiro — chunk por sentença pra baixar TTFA).

## Fontes
sherpa-onnx `offline-tts-kokoro-model.cc` / `piper-phonemize-lexicon.cc`; hexgrad/Kokoro-82M `config.json`;
hexgrad/kokoro `export.py`; espeak-ng `speak_lib.h`; ORT C API docs; recursiveGecko/onnxruntime.zig.
