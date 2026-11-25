#!/bin/bash
# Builds build/Snapshot.app.  Run "./build.sh install" to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Snapshot"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "Generating app icon…"
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon_1024.png"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

APP=build/Snapshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapshot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with the local self-signed identity when present, so macOS keeps the
# Screen Recording permission across rebuilds; otherwise fall back to ad-hoc.
if security find-identity -p codesigning 2>/dev/null | grep -q "Snapshot Local Signing"; then
  codesign --force --sign "Snapshot Local Signing" "$APP" >/dev/null
  echo "Signed with: Snapshot Local Signing"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (permission will reset on each rebuild)"
fi
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x Snapshot 2>/dev/null || true
  rm -rf /Applications/Snapshot.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Snapshot.app"
  open /Applications/Snapshot.app
fi
