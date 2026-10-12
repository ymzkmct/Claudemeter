#!/bin/bash
# Builds Claudemeter.app from the SwiftPM package.
#   scripts/build-app.sh            -> build/Claudemeter.app
#   scripts/build-app.sh --install  -> also copies to INSTALL_DIR (default: /Applications) and launches it
# Env: CODESIGN_IDENTITY to force a signing identity (default: first "Apple Development" cert, else ad-hoc "-").
#      INSTALL_DIR to install somewhere other than /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claudemeter"
OUT="build/${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

if ! xcode-select -p | grep -q "Xcode"; then
  echo "warning: active developer dir is $(xcode-select -p); Command Line Tools alone may not build this (SDK/compiler mismatch)." >&2
  echo "         select Xcode with: sudo xcode-select -s <path to Xcode.app>" >&2
fi

swift build -c release

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/${APP_NAME}" "$OUT/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)
fi
if [ -z "$IDENTITY" ]; then
  echo "note: no Apple Development identity found; signing ad-hoc." >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$OUT"
echo "built: $OUT (signed: $IDENTITY)"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "${INSTALL_DIR:?}/${APP_NAME}.app"
  cp -R "$OUT" "${INSTALL_DIR}/${APP_NAME}.app"
  open "${INSTALL_DIR}/${APP_NAME}.app"
  echo "installed and launched: ${INSTALL_DIR}/${APP_NAME}.app"
fi
