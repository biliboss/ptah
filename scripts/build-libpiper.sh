#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Builds libpiper from OHF-Voice/piper1-gpl into vendor/piper1-gpl/.
# Run once; rebuild only when upstream changes.
#
# Output (macOS):
#   vendor/piper1-gpl/libpiper/dist/lib/libpiper.dylib
#   vendor/piper1-gpl/libpiper/dist/lib/libonnxruntime.1.22.0.dylib
#   vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data/
#
# Output (Linux — v1.3 best-effort):
#   vendor/piper1-gpl/libpiper/dist/lib/libpiper.so
#   vendor/piper1-gpl/libpiper/dist/lib/libonnxruntime.so.1.22.0
#   vendor/piper1-gpl/libpiper/dist/share/espeak-ng-data/
#
# Then: zig build -Doptimize=ReleaseFast -Dwith-piper=true
#
# Gotcha: espeak-ng caps phoneme source paths at N_PATH_HOME=160. Long absolute
# paths (>160 chars) silently truncate filenames during cmake. We build in
# /tmp/agent-tts-piper-build and symlink the result into vendor/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor/piper1-gpl"
BUILD_ROOT="/tmp/agent-tts-piper-build"
PIPER_TAG="v1.4.2"   # pinned in CI; bump deliberately

# v1.3 — Per-platform shared-library extension. macOS = .dylib, Linux = .so.
# Windows libpiper builds are untested by this script (cmake would generate
# .dll + .lib but the build.zig rpath wiring assumes Unix paths).
case "$(uname -s)" in
  Darwin) LIB_EXT="dylib" ;;
  Linux)  LIB_EXT="so"    ;;
  *) echo "[build-libpiper] unsupported host '$(uname -s)' — macOS or Linux only" >&2; exit 2 ;;
esac

command -v cmake >/dev/null || { echo "cmake missing — install via brew (macOS) or apt install cmake (Linux)"; exit 1; }
command -v git   >/dev/null || { echo "git missing"; exit 1; }

if [[ -f "$VENDOR_DIR/libpiper/dist/lib/libpiper.$LIB_EXT" ]]; then
  echo "[build-libpiper] libpiper.$LIB_EXT already present — skip (delete vendor/piper1-gpl to force rebuild)"
  exit 0
fi

mkdir -p "$BUILD_ROOT"
if [[ ! -d "$BUILD_ROOT/piper1-gpl/.git" ]]; then
  echo "[build-libpiper] cloning piper1-gpl @ $PIPER_TAG into $BUILD_ROOT"
  git clone --depth 1 --branch "$PIPER_TAG" \
    https://github.com/OHF-Voice/piper1-gpl.git "$BUILD_ROOT/piper1-gpl"
fi

cd "$BUILD_ROOT/piper1-gpl/libpiper"
echo "[build-libpiper] cmake configure"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
echo "[build-libpiper] cmake build (this takes ~10 min cold)"
cmake --build build -j --target piper install

mkdir -p "$VENDOR_DIR"
# Symlink the build output into the repo so build.zig finds it.
ln -sfn "$BUILD_ROOT/piper1-gpl/libpiper" "$VENDOR_DIR/libpiper"

echo "[build-libpiper] DONE"
echo "  libpiper.$LIB_EXT -> $VENDOR_DIR/libpiper/dist/lib/libpiper.$LIB_EXT"
echo "  next: ./scripts/fetch-voice.sh && zig build -Dwith-piper=true"
