#!/bin/zsh
# Assemble the standalone PixelBooth.app bundle (arm64, macOS 27.0+).
# No Homebrew or system codec dependencies at runtime: libavif/libaom are
# statically linked into the executable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
PRODUCT=".build/out/Products/$CONFIG"
if [[ ! -d "$PRODUCT" ]]; then
  PRODUCT=".build/out/Products/Debug"
fi
BIN="$PRODUCT/PixelBooth"
if [[ ! -x "$BIN" ]]; then
  echo "Executable not found at $BIN — run scripts/build_app.sh first." >&2
  exit 1
fi

APP="build/PixelBooth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PixelBooth"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "Support/en.lproj/InfoPlist.strings" "$APP/Contents/Resources/en.lproj/" 2>/dev/null || true

# Sign: ad-hoc by default for local development; pass a Developer ID
# identity to also sign for distribution.
IDENTITY="${1:--}"
codesign --force --sign "$IDENTITY" \
  --entitlements Support/PixelBooth.entitlements \
  --options runtime \
  "$APP" 2>/dev/null || codesign --force -s - --entitlements Support/PixelBooth.entitlements "$APP"

echo "Built $APP"
codesign -dv "$APP" 2>&1 | head -4 || true
