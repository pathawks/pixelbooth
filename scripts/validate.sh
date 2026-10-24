#!/bin/zsh
# Source validation: lint, debug builds, and tests. Does not assemble the .app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/configure_developer_dir.sh

echo "==> Validating source; this does not create or update build/PixelBooth.app"
echo "==> [1/4] Checking Swift formatting and lint rules"
swift format lint --strict --recursive Sources Tests Tools
python3 -B scripts/tests/test_depth_model.py

echo "==> [2/4] Preparing pinned codecs and the selected depth model"
scripts/fetch_deps.sh
DEPTH_SELECTION_FILE="$(mktemp "${TMPDIR:-/tmp}/pixelbooth-depth-selection.XXXXXX")"
trap 'rm -f "$DEPTH_SELECTION_FILE"' EXIT
scripts/fetch_depth_model.sh --selection-file "$DEPTH_SELECTION_FILE"
IFS= read -r DEPTH_RESOURCES < "$DEPTH_SELECTION_FILE"

echo "==> [3/4] Building debug app and test runner (arm64-apple-macos27.0, strict concurrency)"
swift build --product PixelBooth
swift build --product PixelBoothTestRunner

echo "==> [4/4] Running automated test suite"
PIXELBOOTH_DEPTH_MODEL="$DEPTH_RESOURCES/PixelBoothDepth.mlmodelc" \
  PIXELBOOTH_DEPTH_CONFIGURATION="$DEPTH_RESOURCES/DepthModel.json" \
  .build/out/Products/Debug/PixelBoothTestRunner
echo "Validation passed. Run scripts/build_app.sh to create or refresh build/PixelBooth.app."
