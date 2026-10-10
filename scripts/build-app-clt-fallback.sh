#!/bin/bash
# Fallback build WITHOUT Xcode, for the state this machine was in on 2026-10-10:
# Command Line Tools whose `swift-package` crashes (llbuild symbol mismatch) and whose
# default macOS 27 SDK cannot be read by the bundled swiftc 6.1.2.
# It compiles with bare swiftc against the CLT's macOS 15.5 SDK, masking the duplicate
# `SwiftBridging` modulemap with a VFS overlay. Prefer scripts/build-app.sh once Xcode is installed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claudemeter"
OUT="build/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEV_DIR="$(xcode-select -p)"                       # normally the Command Line Tools directory
# Newest SDK the bundled swiftc can still read; override with SDK=<path> if needed.
SDK="${SDK:-$(ls -d "$DEV_DIR"/SDKs/MacOSX15.*.sdk 2>/dev/null | sort -V | tail -1)}"
if [ -z "$SDK" ]; then echo "no usable macOS 15 SDK under $DEV_DIR/SDKs; set SDK=<path>" >&2; exit 1; fi
WORK="$PWD/build/clt-fallback"
mkdir -p "$WORK"

: > "$WORK/empty.modulemap"
cat > "$WORK/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "name": "$DEV_DIR/usr/include/swift", "type": "directory",
    "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$WORK/empty.modulemap" } ] } ] }
YAML

swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 5 \
  -vfsoverlay "$WORK/overlay.yaml" -module-cache-path "$WORK/modcache" \
  -O -wmo -parse-as-library -module-name "$APP_NAME" -o "$WORK/$APP_NAME" Sources/Claudemeter/*.swift

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$WORK/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$OUT"
echo "built: $OUT"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "${INSTALL_DIR:?}/${APP_NAME}.app"
  cp -R "$OUT" "${INSTALL_DIR}/${APP_NAME}.app"
  open "${INSTALL_DIR}/${APP_NAME}.app"
fi
