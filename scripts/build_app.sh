#!/bin/zsh
# Build the PixelBooth executable (arm64, macOS 27.0+, strict concurrency)
# and assemble the standalone .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PixelBooth
exec scripts/make_app.sh release
