#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Downloads the en_US Amy medium voice from rhasspy/piper-voices into
# ~/.cache/ptah/voices/. v1.1 wires this voice into MultiPiperEngine for
# code-switch routing (Pt sentences → Faber, En sentences → Amy).
#
# Voice license: see https://github.com/rhasspy/piper-voices (typically CC-BY-NC).
# ptah does NOT redistribute this model.

set -euo pipefail

VOICES_DIR="$HOME/.cache/ptah/voices"
VOICE_NAME="en_US-amy-medium"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium"

mkdir -p "$VOICES_DIR"

for ext in onnx onnx.json; do
  dest="$VOICES_DIR/$VOICE_NAME.$ext"
  if [[ -f "$dest" ]]; then
    echo "[fetch-voice-en] $dest already present — skip"
    continue
  fi
  echo "[fetch-voice-en] downloading $VOICE_NAME.$ext"
  curl -fL "$BASE_URL/$VOICE_NAME.$ext" -o "$dest"
done

echo "[fetch-voice-en] DONE"
echo "  voice: $VOICES_DIR/$VOICE_NAME.onnx"
echo "  next: zig build -Dwith-piper=true && PTAH_PIPER=1 ptah daemon"
echo "  test: ptah --lang en \"Hello, world\""
