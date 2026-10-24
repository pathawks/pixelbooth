#!/bin/zsh
# Build an ordinary arm64/macOS 27 command-line executable with camera privacy
# metadata. The SwiftUI application and its sandbox are separate products.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/configure_cli_developer_dir.sh

WITH_DISPARITY=false
case "${1:-}" in
  "") ;;
  --with-disparity) WITH_DISPARITY=true ;;
  *) print -u2 "Usage: scripts/build_cli.sh [--with-disparity]"; exit 2 ;;
esac
if (( $# > 1 )); then
  print -u2 "Usage: scripts/build_cli.sh [--with-disparity]"
  exit 2
fi

swift format lint --strict --recursive Sources Tests Tools
python3 -B scripts/tests/test_depth_model.py
scripts/fetch_deps.sh
scripts/stage_headers.sh
swift build --arch arm64 -c release --product PixelBoothCLI
BIN_DIRECTORY="$(swift build --arch arm64 -c release --show-bin-path)"

mkdir -p build
CLI_STAGING="$(mktemp -d "$PWD/build/.pixelbooth-cli.XXXXXX")"
trap 'rm -rf "$CLI_STAGING"' EXIT
cp "$BIN_DIRECTORY/PixelBoothCLI" "$CLI_STAGING/pixelbooth"
plutil -lint Support/CLIInfo.plist Support/CLI.entitlements
codesign --force --sign - --identifier app.pixelbooth.cli --options runtime \
  --entitlements Support/CLI.entitlements "$CLI_STAGING/pixelbooth"
codesign --verify --strict --verbose=2 "$CLI_STAGING/pixelbooth"

if [[ "$WITH_DISPARITY" == true ]]; then
  scripts/fetch_depth_model.sh --selection-file "$CLI_STAGING/depth-selection.txt"
  IFS= read -r DEPTH_RESOURCES < "$CLI_STAGING/depth-selection.txt"
  mkdir "$CLI_STAGING/pixelbooth-resources"
  cp -R "$DEPTH_RESOURCES/PixelBoothDepth.mlmodelc" "$CLI_STAGING/pixelbooth-resources/"
  cp "$DEPTH_RESOURCES/DepthModel.json" "$DEPTH_RESOURCES/model-LICENSE" \
    "$CLI_STAGING/pixelbooth-resources/"
fi

mkdir -p build/pixelbooth-notices
cp vendor/notices/* build/pixelbooth-notices/
rm -rf build/pixelbooth-resources
if [[ "$WITH_DISPARITY" == true ]]; then
  mv "$CLI_STAGING/pixelbooth-resources" build/pixelbooth-resources
fi
mv -f "$CLI_STAGING/pixelbooth" build/pixelbooth
print "Built $PWD/build/pixelbooth"
