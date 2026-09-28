#!/bin/zsh
# Make the vendored header search paths inside SwiftPM's generated response
# files absolute, by copying pinned headers into the shim target's own
# public headers directory (this avoids any working-directory dependency).
set -euo pipefail
cd "$(dirname "$0")/.."

# Copy pinned headers into the shim's include dir so plain header search
# resolves without extra -I flags.
if [[ -d vendor/build/avif-install/include/avif ]]; then
  mkdir -p Tools/PixelBoothCAvif/include/avif
  cp vendor/build/avif-install/include/avif/*.h Tools/PixelBoothCAvif/include/avif/ 2>/dev/null || true
fi
if [[ -d vendor/build/avif-install/include ]]; then
  mkdir -p Tools/PixelBoothCAvif/include/avif
  cp vendor/build/avif-install/include/avif/avif.h Tools/PixelBoothCAvif/include/avif/ 2>/dev/null || true
  cp vendor/build/avif-install/include/avif/avif_cxx.h Tools/PixelBoothCAvif/include/avif/ 2>/dev/null || true
fi
echo "Headers staged."
