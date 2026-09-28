#!/bin/zsh
# Full build + test pipeline for a fresh checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1/3] Fetching and building pinned native dependencies (libavif 1.3.0, libaom 3.13.1)"
scripts/fetch_deps.sh

echo "==> [2/3] Building all targets (arm64-apple-macos27.0, strict concurrency)"
swift build --product PixelBooth
swift build --product PixelBoothTestRunner

echo "==> [3/3] Running automated test suite"
.build/out/Products/Debug/PixelBoothTestRunner
