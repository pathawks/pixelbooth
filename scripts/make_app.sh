#!/bin/zsh
# Assemble the standalone PixelBooth.app bundle (arm64, macOS 27.0+).
# No Homebrew or system codec dependencies at runtime: libavif/libaom are
# statically linked into the executable.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${2:--}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "Usage: scripts/make_app.sh [debug|release] [signing-identity]" >&2; exit 2 ;;
esac
PRODUCT=".build/out/Products/release"
if [[ "$CONFIG" == debug ]]; then
  PRODUCT=".build/out/Products/Debug"
fi
BIN="$PRODUCT/PixelBooth"
if [[ ! -x "$BIN" ]]; then
  echo "Executable for the requested $CONFIG configuration was not found at $BIN — run scripts/build_app.sh first." >&2
  exit 1
fi

APP="build/PixelBooth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PixelBooth"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "Support/en.lproj/InfoPlist.strings" "$APP/Contents/Resources/en.lproj/"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp vendor/notices/* "$APP/Contents/Resources/ThirdPartyNotices/"

# Sign: ad-hoc by default for local development; pass a Developer ID
# identity to also sign for distribution.
codesign --force --sign "$IDENTITY" \
  --entitlements Support/PixelBooth.entitlements \
  --options runtime \
  "$APP"

scripts/check_app_permissions.sh "$APP"

echo "Built $APP"
codesign -dv "$APP" 2>&1 | head -4 || true
