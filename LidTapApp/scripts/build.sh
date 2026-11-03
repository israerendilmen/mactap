#!/bin/sh
# Builds LidTap.app and installs it to ~/Applications.
#   scripts/build.sh            release build + install
#   scripts/build.sh --no-install
set -e
MODE="$1"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/LidTap.app"
SDK="$(xcrun --show-sdk-path)"

# Command Line Tools 26.1 on this Mac ships a stray usr/include/swift/module.modulemap that redefines
# SwiftBridging and breaks every Foundation import. Hide it with a VFS overlay (no system files touched).
FIX="$ROOT/scripts/toolchain-fix"
mkdir -p "$FIX"
: > "$FIX/empty.modulemap"
cat > "$FIX/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
  "external-contents": "$FIX/empty.modulemap" } ] }
EOF
swiftc_() { swiftc -sdk "$SDK" -target arm64-apple-macos14.0 -vfsoverlay "$FIX/overlay.yaml" "$@"; }

mkdir -p "$BUILD"
echo "Compiling…"
set --
for f in $(cd Sources && find . -name '*.swift'); do set -- "$@" "Sources/$f"; done
swiftc_ -O -swift-version 5 -parse-as-library \
  -framework IOKit -framework CoreAudio -framework CoreMediaIO -framework ServiceManagement \
  "$@" -o "$BUILD/LidTap"

echo "Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/LidTap" "$APP/Contents/MacOS/LidTap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  swiftc_ -O scripts/make_icon.swift -o "$BUILD/make_icon"
  rm -rf "$BUILD/AppIcon.iconset"
  "$BUILD/make_icon" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Hardened Runtime: no injected dylibs, no debugger attach, no unsigned code. Set LIDTAP_SIGN_ID to a
# "Developer ID Application: …" identity to sign for distribution (then notarize with notarytool).
if [ -n "$LIDTAP_SIGN_ID" ]; then STAMP="--timestamp"; else STAMP="--timestamp=none"; fi  # notarization needs a secure timestamp
codesign --force --options runtime "$STAMP" --entitlements Resources/LidTap.entitlements \
  --sign "${LIDTAP_SIGN_ID:--}" --identifier dev.lidtap.LidTap "$APP"

if [ "$MODE" != "--no-install" ]; then
  DEST="$HOME/Applications/LidTap.app"
  mkdir -p "$HOME/Applications"
  pkill -x LidTap 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed to $DEST"
fi
echo "Done."
