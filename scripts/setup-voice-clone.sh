#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# setup-voice-clone.sh — bootstrap the Python sidecar for `ptah voice clone`.
#
# Idempotent. Prefers `uv` (lockfile-clean, fast); falls back to `python3 -m
# venv` if uv is missing. Installs Coqui TTS (MPL-2.0) into a project-local
# venv so the Zig binary keeps its dual MIT/Apache license envelope.
#
# Run once:
#   ./scripts/setup-voice-clone.sh
#
# Re-run safely — the script no-ops on every step that's already satisfied.
#
# Notes:
#   - XTTS-v2 model (~1.8 GB) is downloaded on first run by Coqui itself,
#     NOT by this script. We don't pre-pull because Coqui caches it where
#     the runtime expects it (~/Library/Application Support/tts/ on macOS).
#   - On Apple Silicon, MPS works on torch >= 2.1 but XTTS-v2 falls back to
#     CPU for a few ops. Cold synth runs ~6-10s; warm ~500-900ms first sample.
#   - macOS may need `pip install soundfile` separately if libsndfile isn't
#     on PATH — we install it here to keep first-run boring.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_ROOT="$(pwd)"
VENV_DIR="${PROJECT_ROOT}/.venv-voice"

log() { printf "[setup-voice-clone] %s\n" "$*" >&2; }

if command -v uv >/dev/null 2>&1; then
    log "uv detected — Zig sidecar will use \`uv run --with TTS\` (no venv needed)"
    # We still create the venv as a deterministic install target so users
    # can pip-debug from a stable place. uv will reuse it via UV_PROJECT_ENV.
    if [[ ! -d "${VENV_DIR}" ]]; then
        log "creating venv at ${VENV_DIR}"
        uv venv --python 3.11 "${VENV_DIR}"
    fi
    # Install Coqui TTS (community fork) + scipy for high-quality resampling.
    # Three real blockers hit on 2026-06-03 / macOS arm64 — keep these pins
    # honest until coqui-tts publishes a release that handles them upstream:
    #   1. `transformers<5` — coqui-tts 0.27 imports
    #      `transformers.pytorch_utils.isin_mps_friendly`, removed in v5.
    #   2. `torch<2.9` — torch 2.9+ forces torchcodec for audio I/O,
    #      torchcodec links against ffmpeg 4.x's libavutil.56.dylib, and
    #      Homebrew's current ffmpeg is 8.x (libavutil.62). torch 2.8 ships
    #      a torchaudio I/O path that uses soundfile/libsndfile instead —
    #      already on PATH because we install `soundfile`.
    #   3. torch + torchaudio aren't declared by coqui-tts but are mandatory
    #      at runtime — install explicitly so the venv is self-sufficient.
    log "installing coqui-tts + torch<2.9 + scipy into ${VENV_DIR}"
    UV_PROJECT_ENV="${VENV_DIR}" uv pip install --python "${VENV_DIR}/bin/python" \
        "coqui-tts>=0.27.0" \
        "transformers<5" \
        "torch<2.9" \
        "torchaudio<2.9" \
        scipy \
        soundfile
    log "OK — voice clone sidecar ready. Try:"
    log "  ptah voice clone --sample me.wav --name gabriel"
    exit 0
fi

log "uv not found — falling back to python3 -m venv"
if ! command -v python3 >/dev/null 2>&1; then
    log "error: python3 not on PATH. Install Python 3.10+ first." >&2
    exit 1
fi

if [[ ! -d "${VENV_DIR}" ]]; then
    log "creating venv at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
fi

# Activate the venv shellishly so pip lands in the right place.
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

log "upgrading pip + installing coqui-tts"
python -m pip install --upgrade pip
# See note above on transformers<5 + torch<2.9 — applies to both `uv` and
# the plain-venv path. Keep both branches in sync.
python -m pip install \
    "coqui-tts>=0.27.0" \
    "transformers<5" \
    "torch<2.9" \
    "torchaudio<2.9" \
    scipy \
    soundfile

log "OK — voice clone sidecar ready. Activate the venv before running scripts:"
log "  source ${VENV_DIR}/bin/activate"
log "  ptah voice clone --sample me.wav --name gabriel"
