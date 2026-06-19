#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Downloads the Pt-BR Faber medium voice from rhasspy/piper-voices into
# ~/.cache/ptah/voices/.
#
# Voice license: see https://github.com/rhasspy/piper-voices (typically CC-BY-NC).
# ptah does NOT redistribute this model.

set -euo pipefail

VOICES_DIR="$HOME/.cache/ptah/voices"
VOICE_NAME="pt_BR-faber-medium"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium"

mkdir -p "$VOICES_DIR"

for ext in onnx onnx.json; do
  dest="$VOICES_DIR/$VOICE_NAME.$ext"
  if [[ -f "$dest" ]]; then
    echo "[fetch-voice] $dest already present — skip"
    continue
  fi
  echo "[fetch-voice] downloading $VOICE_NAME.$ext"
  curl -fL "$BASE_URL/$VOICE_NAME.$ext" -o "$dest"
done

echo "[fetch-voice] DONE"
echo "  voice: $VOICES_DIR/$VOICE_NAME.onnx"
echo "  next: zig build -Dwith-piper=true && PTAH_PIPER=1 ptah daemon"
