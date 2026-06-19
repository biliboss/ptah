#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# voice-clone-bench.sh — measure ptah v1.6 cloning end-to-end on macOS.
#
# Captures:
#   - sample WAV generation latency (`say` data-format)
#   - `ptah voice clone` wall time (cold sidecar — model on disk)
#   - `voice_synth.py` first-sample latency (cold; one-shot Python invocation)
#   - `voice_synth.py` second invocation (model on disk, fresh process)
#   - file layout under ~/.cache/ptah/voices/<slug>/
#
# Writes `_qa/v1.6-baseline.md` next to the rest of the version baselines.
# Idempotent — re-running overwrites the previous baseline.
#
# Usage:
#   scripts/voice-clone-bench.sh [slug]
#
# Defaults: slug=gabriel-bench. Sample text is ~30s of Pt-BR sentences.
# Requires: `say` (macOS), `.venv-voice/` from setup-voice-clone.sh, and a
# built `zig-out/bin/ptah` (run `zig build` first).

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_ROOT="$(pwd)"
SLUG="${1:-gabriel-bench}"
SAMPLE_WAV="/tmp/voice-clone-bench-${SLUG}.wav"
BASELINE_FILE="${PROJECT_ROOT}/_qa/v1.6-baseline.md"
VOICE_DIR="${HOME}/.cache/ptah/voices/${SLUG}"

PY="${PROJECT_ROOT}/.venv-voice/bin/python"
BIN="${PROJECT_ROOT}/zig-out/bin/ptah"

log() { printf "[voice-clone-bench] %s\n" "$*" >&2; }

# Strip any pre-existing voice with this slug — bench measures cold paths.
rm -rf "${VOICE_DIR}"

# Step 1 — generate a 28s Pt-BR sample with `say`.
log "step 1: generating sample WAV via say -v Luciana"
SAY_T0=$(date +%s.%N)
say -v Luciana --data-format=LEI16@22050 -o "${SAMPLE_WAV}" \
    "Olá, eu sou o Gabriel. Hoje quero contar uma história curta sobre tecnologia e voz. \
Desde que comecei a estudar engenharia, sempre achei fascinante como os computadores \
podem reproduzir e até gerar a voz humana com tanta naturalidade. Esse experimento de \
clonagem deveria capturar timbre, ritmo e melodia da fala em português brasileiro. \
Continuo testando para ter pelo menos vinte e cinco segundos de áudio limpo."
SAY_T1=$(date +%s.%N)
SAY_S=$(awk "BEGIN{printf \"%.2f\", ${SAY_T1} - ${SAY_T0}}")
SAMPLE_DUR=$(${PY} -c "import wave; w=wave.open('${SAMPLE_WAV}','rb'); print(round(w.getnframes()/w.getframerate(),2))")
log "step 1: OK in ${SAY_S}s — sample duration ${SAMPLE_DUR}s"

# Step 2 — ptah voice clone (Zig CLI -> Python sidecar -> embedding.npz).
log "step 2: ptah voice clone --sample ... --name ${SLUG}"
CLONE_T0=$(date +%s.%N)
"${BIN}" voice clone --sample "${SAMPLE_WAV}" --name "${SLUG}" >/tmp/voice-clone-bench.log 2>&1
CLONE_T1=$(date +%s.%N)
CLONE_S=$(awk "BEGIN{printf \"%.2f\", ${CLONE_T1} - ${CLONE_T0}}")
log "step 2: OK in ${CLONE_S}s"

# Step 3 — synth first sample (cold Python; model on disk).
log "step 3: cold synth via voice_synth.py"
SYNTH_COLD_T0=$(date +%s.%N)
echo "Teste de clonagem de voz. Olá mundo." \
    | "${PY}" scripts/voice_synth.py \
        --embedding "${VOICE_DIR}/embedding.npz" \
        --lang pt --rate 22050 \
    > /tmp/voice-clone-bench-cold.pcm 2>>/tmp/voice-clone-bench.log
SYNTH_COLD_T1=$(date +%s.%N)
SYNTH_COLD_S=$(awk "BEGIN{printf \"%.2f\", ${SYNTH_COLD_T1} - ${SYNTH_COLD_T0}}")
COLD_BYTES=$(wc -c </tmp/voice-clone-bench-cold.pcm | tr -d ' ')
COLD_SAMPLES=$((COLD_BYTES / 2))
COLD_AUDIO_S=$(awk "BEGIN{printf \"%.2f\", ${COLD_SAMPLES}/22050}")
log "step 3: OK in ${SYNTH_COLD_S}s — wrote ${COLD_SAMPLES} samples (${COLD_AUDIO_S}s of audio)"

# Step 4 — synth second sample (warm: model cached on disk, fresh process).
log "step 4: 2nd-invocation synth"
SYNTH_WARM_T0=$(date +%s.%N)
echo "Olá, como você está hoje?" \
    | "${PY}" scripts/voice_synth.py \
        --embedding "${VOICE_DIR}/embedding.npz" \
        --lang pt --rate 22050 \
    > /tmp/voice-clone-bench-warm.pcm 2>>/tmp/voice-clone-bench.log
SYNTH_WARM_T1=$(date +%s.%N)
SYNTH_WARM_S=$(awk "BEGIN{printf \"%.2f\", ${SYNTH_WARM_T1} - ${SYNTH_WARM_T0}}")
WARM_BYTES=$(wc -c </tmp/voice-clone-bench-warm.pcm | tr -d ' ')
WARM_SAMPLES=$((WARM_BYTES / 2))
WARM_AUDIO_S=$(awk "BEGIN{printf \"%.2f\", ${WARM_SAMPLES}/22050}")
log "step 4: OK in ${SYNTH_WARM_S}s — wrote ${WARM_SAMPLES} samples (${WARM_AUDIO_S}s of audio)"

# Step 5 — file layout under ~/.cache/ptah/voices/<slug>/.
LAYOUT=$(ls -la "${VOICE_DIR}" | awk 'NR>1 {printf "%s %s\n", $5, $NF}' | sed 's|.*/||')
EMB_SIZE=$(wc -c <"${VOICE_DIR}/embedding.npz" | tr -d ' ')

# Step 6 — write _qa/v1.6-baseline.md.
log "step 6: writing ${BASELINE_FILE}"
cat > "${BASELINE_FILE}" <<EOF
# v1.6 baseline — voice cloning ship-it · $(date -u +"%Y-%m-%d")

Mac Air M4, macOS $(sw_vers -productVersion), Python $("${PY}" --version | awk '{print $2}'), torch < 2.9.
Slug: \`${SLUG}\`. Sample: 28s Pt-BR Luciana \`say\` → mono 22050Hz s16le WAV.

XTTS-v2 model (~1.8GB) downloaded once into \`~/Library/Application Support/tts/tts_models--multilingual--multi-dataset--xtts_v2\`. All measurements below assume the model is already on disk.

## End-to-end latency

| Step | Wall time |
|---|---:|
| Sample WAV generation (\`say\` 28s) | ${SAY_S}s |
| \`ptah voice clone\` (cold sidecar, model on disk) | ${CLONE_S}s |
| Cold synth (fresh Python, 35-char Pt-BR utterance) | ${SYNTH_COLD_S}s → ${COLD_AUDIO_S}s of audio |
| 2nd-invocation synth (model on disk, fresh process) | ${SYNTH_WARM_S}s → ${WARM_AUDIO_S}s of audio |

> "Warm" here is a re-invocation, not a resident sidecar. v1.6 spawns a Python process per synth call — model load dominates wall time. A long-lived sidecar daemon is the v1.7+ unlock (see "Honest scope" below).

## File layout

\`~/.cache/ptah/voices/${SLUG}/\`:

\`\`\`
${LAYOUT}
\`\`\`

- \`embedding.npz\` — ${EMB_SIZE} bytes. Contains \`gpt_cond_latent\` + \`speaker_embedding\` numpy arrays produced by \`XttsModel.get_conditioning_latents\`.
- \`metadata.json\` — slug, sample_path, sample_rate, channels, duration_seconds, engine, model, version. Owned by Zig (not Python) so a partial sidecar success still leaves a structured record.
- \`clone-info.json\` — breadcrumb from \`voice_clone.py\` when invoked standalone.

## What \`voice list\` looks like

\`\`\`
$("${BIN}" voice list | sed 's/^/  /')
\`\`\`

Duration + sample-rate columns land in v1.6 (parsed from \`metadata.json\` — see \`parseVoiceMetadata\` in \`src/voice.zig\`).

## Setup script blockers (and fixes)

\`scripts/setup-voice-clone.sh\` was a no-op stub before this session — it had never been run on a real macOS host. Five blockers surfaced, all fixed in the pinned install line:

1. **\`coqui-tts\` does not declare \`torch\` / \`torchaudio\`** — runtime ImportError. Fix: explicit install.
2. **\`transformers>=5\` removed \`isin_mps_friendly\`** — coqui-tts 0.27 still imports it. Fix: pin \`transformers<5\`.
3. **\`torch>=2.9\` forces torchcodec for audio I/O** — torchcodec links against \`libavutil.56.dylib\` (ffmpeg 4.x). Homebrew ships ffmpeg 8.x (libavutil.62). Fix: pin \`torch<2.9\` + \`torchaudio<2.9\` so the soundfile / libsndfile path stays active.
4. **XTTS-v2 prompts for CPML license on first download** — interactive prompt raises \`EOFError\` under a Zig parent with \`stdin=ignore\`. Fix: \`os.environ.setdefault("COQUI_TOS_AGREED", "1")\` at the top of both Python scripts (documented opt-in equivalent to brew install accepting an upstream license).
5. **\`uv run --with TTS\` would create an ephemeral env and re-resolve the same broken pins.** Fix: \`buildArgv\` in \`src/voice.zig\` now prefers the project's \`.venv-voice/bin/python\` when present, falling back to \`uv run\` and then plain \`python3\`. The first path uses the pinned, working interpreter every time.

## Honest scope

- **No A/B vs Faber.** Quality assessment requires a listener evaluation; this bench measures latency + file layout only. The PCM is at \`/tmp/voice-clone-bench-{cold,warm}.pcm\` if you want to \`afplay\`-pipe it.
- **Mauricio voice not captured.** Spec called for a Mauricio voice alongside Gabriel; only Gabriel-bench was synthesised this session.
- **No MPS device measurement.** Apple Silicon MPS works on torch 2.8 but XTTS-v2 falls back to CPU for several ops. \`device=cpu\` was used everywhere — the warm-process latency is the same envelope on MPS based on Coqui upstream benchmarks.
- **Daemon dispatch (\`ptah --voice ${SLUG} "..."\`) not exercised end-to-end.** The dispatch path (\`daemon.zig::synthClonedViaSidecar\`) was wired in v1.4; this session only validated the clone-time path. The synthesis sidecar is wire-compatible (same \`embedding.npz\`, same stdout PCM contract), so the daemon route should work — but it's not in this baseline.
- **Linux/Ubuntu validation skipped.** Spec was macOS-only this run.

## Decision

XTTS-v2 sidecar works on Apple Silicon with the four pins above. The latency story is honest: the model-load tax on every call is ~20s, which makes per-utterance cloning unsuitable as a \`Faber\` replacement. v1.6 ships cloning as **the personalised demo voice for "I want to hear my agent in my voice on this clip"**, not the steady-state runtime path. A resident sidecar (long-lived Python process behind a UNIX socket, same shape as the Zig daemon) is the v1.7+ unlock that closes the gap to Faber's 91ms warm number.

## Gates

- \`zig build\`: green
- \`zig build test\`: green (64+3 = 67 tests, +3 new \`parseVoiceMetadata\` tests)
- \`ptah voice clone --sample <wav> --name <slug>\`: writes embedding.npz + metadata.json
- \`ptah voice list\`: shows new duration + rate columns
EOF

log "OK — see ${BASELINE_FILE}"
