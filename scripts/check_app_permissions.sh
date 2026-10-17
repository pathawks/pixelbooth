#!/bin/zsh
# Inspect the assembled, signed bundle without requesting permissions or
# accessing the user's Photos library. Resource entitlements and PhotoKit
# authorization levels are separate: routine captures still request add-only.
set -euo pipefail

if [[ "$#" != 1 ]]; then
  echo "Usage: scripts/check_app_permissions.sh /path/to/PixelBooth.app" >&2
  exit 2
fi

PIXELBOOTH_APP="$1"
PIXELBOOTH_INFO="$PIXELBOOTH_APP/Contents/Info.plist"
PIXELBOOTH_ENTITLEMENTS="$(mktemp -t pixelbooth-signed-entitlements)"
trap 'rm -f "$PIXELBOOTH_ENTITLEMENTS"' EXIT

fail() {
  echo "App permission configuration is invalid: $1" >&2
  exit 1
}

codesign --verify --strict "$PIXELBOOTH_APP"
codesign --display --entitlements - --xml "$PIXELBOOTH_APP" > "$PIXELBOOTH_ENTITLEMENTS"
plutil -lint "$PIXELBOOTH_INFO" "$PIXELBOOTH_ENTITLEMENTS" >/dev/null

for key in \
  com.apple.security.app-sandbox \
  com.apple.security.device.camera \
  com.apple.security.personal-information.location \
  com.apple.security.personal-information.photos-library \
  com.apple.security.files.user-selected.read-write; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PIXELBOOTH_ENTITLEMENTS" 2>/dev/null)" \
    || fail "missing signed entitlement $key"
  [[ "$value" == true ]] || fail "signed entitlement $key must be enabled"
done

if /usr/libexec/PlistBuddy -c "Print :com.apple.security.photos.add" \
  "$PIXELBOOTH_ENTITLEMENTS" >/dev/null 2>&1; then
  fail "com.apple.security.photos.add is not a documented macOS Photos entitlement"
fi

for key in \
  NSCameraUsageDescription \
  NSLocationWhenInUseUsageDescription \
  NSPhotoLibraryAddUsageDescription \
  NSPhotoLibraryUsageDescription; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PIXELBOOTH_INFO" 2>/dev/null)" \
    || fail "missing usage description $key"
  [[ "$value" == *[^[:space:]]* ]] || fail "usage description $key must not be empty"
done

if /usr/libexec/PlistBuddy -c "Print :NSLocationUsageDescription" \
  "$PIXELBOOTH_INFO" >/dev/null 2>&1; then
  fail "use NSLocationWhenInUseUsageDescription for while-in-use location access"
fi

echo "Signed app entitlements and privacy usage descriptions verified."
