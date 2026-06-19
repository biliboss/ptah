#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# build-menubar.sh — produce a redistributable AgentTTSMenubar.app from the
# Swift Package under ui/menubar/.
#
# Pipeline:
#   1. swift build -c release in ui/menubar/
#   2. Assemble a minimal .app bundle (Info.plist with LSUIElement=true)
#   3. Copy the binary into Contents/MacOS/
#
# Output: ui/menubar/build/AgentTTSMenubar.app
#
# v1.10.2: bundles AppIcon.icns generated from public/logos/ptah-logo.png.
# Codesigning + notarization are still out of scope — Gatekeeper treats the
# unsigned bundle as "from unidentified developer". v1.10.2 wires brew cask.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_ROOT/ui/menubar"
OUT_DIR="$PKG_DIR/build"
APP_NAME="AgentTTSMenubar"
APP="$OUT_DIR/$APP_NAME.app"

if [ ! -d "$PKG_DIR" ]; then
  echo "error: $PKG_DIR not found" >&2
  exit 1
fi

cd "$PKG_DIR"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: built binary missing at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# v1.10.2: bake AppIcon.icns from the marketing logo (1024 RGBA → sips →
# iconutil). Requires `sips` + `iconutil` (macOS native).
LOGO="$REPO_ROOT/public/logos/ptah-logo.png"
if [ -f "$LOGO" ]; then
  echo "==> building AppIcon.icns from $LOGO"
  ICONSET=$(mktemp -d)/ptah.iconset
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$LOGO" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
  done
  cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
  cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
  cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
  cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
  cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null
  rm -rf "$ICONSET"
else
  echo "warn: $LOGO not found — bundle will use generic icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.biliboss.ptah.menubar</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>ptah</string>
  <key>CFBundleVersion</key><string>1.10.13</string>
  <key>CFBundleShortVersionString</key><string>1.10.13</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>ptah needs your microphone to record the voice sample used for cloning. Recording only happens when you tap Record in the Clone window.</string>
</dict>
</plist>
PLIST

echo "==> $APP ready"
echo "    open '$APP'   # or"
echo "    '$APP/Contents/MacOS/$APP_NAME'"
