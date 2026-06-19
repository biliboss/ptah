#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# ptah v1.9 — WASM build scaffold.
#
# This script is an executable readme. v1.9 ships the playground UI scaffold
# only — the real WASM Piper synth lands in v1.9.1. Running this today prints
# the four-step plan and exits cleanly so CI does not fail.
#
# When v1.9.1 lands, the "REAL STEPS START HERE" block becomes live cmake +
# emmake + zig build invocations. The shell flow (toolchain check, output
# layout, copy into public/wasm/) is already correct.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPER_SRC="$REPO_ROOT/vendor/piper1-gpl"
WASM_BUILD="/tmp/ptah-wasm-build"
WASM_OUT="$REPO_ROOT/public/wasm"

usage() {
  cat <<EOF
build-wasm.sh — ptah v1.9 WASM build scaffold

Usage:
  $(basename "$0") --plan       # print the v1.9.1 plan and exit (default)
  $(basename "$0") --check      # check that the host has Emscripten + zig wasm target
  $(basename "$0") --run        # v1.9.1 only: actually build (no-op today)
  $(basename "$0") --help       # this message

Today (v1.9): every mode prints the plan. v1.9.1 wires the real cmake calls.
EOF
}

MODE="${1:---plan}"
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  --plan|--check|--run) ;;
  *) usage; exit 2 ;;
esac

print_plan() {
  cat <<'EOF'

ptah v1.9.1 — WASM build plan (4 steps)

  1. Toolchain
     - Install Emscripten SDK 3.1.x:
         git clone https://github.com/emscripten-core/emsdk.git ~/emsdk
         ~/emsdk/emsdk install latest && ~/emsdk/emsdk activate latest
         source ~/emsdk/emsdk_env.sh
     - Zig 0.16+ already covers the wasm32-emscripten target via
         zig build -Dtarget=wasm32-emscripten

  2. libpiper for wasm32-emscripten
     - emcmake cmake -S vendor/piper1-gpl/libpiper -B /tmp/ptah-wasm-build/libpiper \
         -DCMAKE_BUILD_TYPE=Release -DPIPER_BUILD_SHARED=OFF
     - emmake make -C /tmp/ptah-wasm-build/libpiper -j$(sysctl -n hw.ncpu)
     - Output: /tmp/ptah-wasm-build/libpiper/libpiper.a (static archive)

  3. ONNX Runtime Web
     - npm install onnxruntime-web --save
     - Copy node_modules/onnxruntime-web/dist/ort-wasm-simd.wasm into public/wasm/
     - Wire onnxruntime-web JS as the session host for the libpiper-emitted phonemes

  4. Zig build target
     - Add a wasm target to build.zig:
         const wasm = b.addExecutable(.{ .name = "ptah", .target = wasm32-emscripten });
         wasm.linkLibrary(libpiper_wasm);
     - zig build -Dtarget=wasm32-emscripten -Dwith-piper-wasm=true
     - Output: zig-out/bin/ptah.wasm + ptah.js (Emscripten shim)
     - Copy both into public/wasm/, the playground widget imports the .js shim

Output layout (public/wasm/ after v1.9.1):
   ptah.wasm           — Zig + libpiper bundle (~3-5 MB)
   ptah.js             — Emscripten loader shim
   ort-wasm-simd.wasm       — ONNX Runtime Web
   ort-wasm-simd.jsep.wasm  — optional JSEP variant for WebGPU acceleration

Voices stay on Cloudflare R2 (free egress), lazy-loaded on first Speak click.
First-call cold latency budget: < 1.5 s including 63 MB Faber ONNX over a
residential connection. Subsequent calls: browser cache, ~100-200 ms.

EOF
}

check_toolchain() {
  local ok=1
  echo "[build-wasm] toolchain check (v1.9 scaffold — informational only)"
  if command -v emcc >/dev/null 2>&1; then
    echo "  emcc:   $(emcc --version | head -1)"
  else
    echo "  emcc:   MISSING — install Emscripten SDK (https://emscripten.org/docs/getting_started/downloads.html)"
    ok=0
  fi
  if command -v zig >/dev/null 2>&1; then
    echo "  zig:    $(zig version)"
  else
    echo "  zig:    MISSING — install via brew install zig (Apple Silicon) or zig.guide"
    ok=0
  fi
  if [ -d "$PIPER_SRC" ]; then
    echo "  piper:  $PIPER_SRC present"
  else
    echo "  piper:  $PIPER_SRC missing — run scripts/build-libpiper.sh once to fetch sources"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "[build-wasm] toolchain ready for v1.9.1"
  else
    echo "[build-wasm] toolchain incomplete — v1.9.1 will block on the items above"
  fi
}

case "$MODE" in
  --plan)
    print_plan
    echo "[build-wasm] v1.9 scaffold — no build executed. Re-run with --check or --run after v1.9.1 ships."
    ;;
  --check)
    check_toolchain
    print_plan
    ;;
  --run)
    echo "[build-wasm] v1.9 scaffold — --run is a no-op until v1.9.1 wires the real cmake calls."
    print_plan
    echo "[build-wasm] would have written to: $WASM_OUT"
    echo "[build-wasm] would have built in:   $WASM_BUILD"
    ;;
esac
