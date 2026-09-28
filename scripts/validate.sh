#!/bin/zsh
# Source validation: lint, debug builds, and tests. Does not assemble the .app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/configure_developer_dir.sh

echo "==> Validating source; this does not create or update build/PixelBooth.app"
echo "==> [1/4] Checking Swift formatting and lint rules"
swift format lint --strict --recursive Sources Tests Tools

echo "==> [2/4] Fetching and building pinned native dependencies (libavif 1.3.0, libaom 3.13.1)"
scripts/fetch_deps.sh

echo "==> [3/4] Building debug app and test runner (arm64-apple-macos27.0, strict concurrency)"
swift build --product PixelBooth
swift build --product PixelBoothTestRunner

echo "==> [4/4] Running automated test suite"
.build/out/Products/Debug/PixelBoothTestRunner
echo "Validation passed. Run scripts/build_app.sh to create or refresh build/PixelBooth.app."
