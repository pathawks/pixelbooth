#!/bin/zsh
# Build the PixelBooth executable (arm64, macOS 27.0+, strict concurrency)
# and assemble the standalone .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/configure_developer_dir.sh

swift format lint --strict --recursive Sources Tests Tools
echo "==> Building and assembling the release app; this replaces build/PixelBooth.app"
swift build -c release --product PixelBooth
exec scripts/make_app.sh release
