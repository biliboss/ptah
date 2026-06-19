#!/usr/bin/env bash
# Fetch the Kokoro v1.0 ONNX model into assets/ (gitignored, ~310 MB).
# The Dora voice pack (assets/pf_dora.bin) is committed; only the model is
# fetched on demand. Idempotent: skips if already present.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
DEST="assets/kokoro-v1.0.onnx"
URL="https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model.onnx"

if [ -f "$DEST" ]; then
  echo "✓ $DEST already present ($(du -h "$DEST" | cut -f1)) — skip"
  exit 0
fi

echo "→ fetching Kokoro v1.0 model (~310 MB) into $DEST …"
mkdir -p assets
curl -fSL --retry 3 -o "$DEST" "$URL"
echo "✓ $DEST ($(du -h "$DEST" | cut -f1))"
echo "  next: zig build -Doptimize=ReleaseFast && ptah daemon"
