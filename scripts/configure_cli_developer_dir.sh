# Source from the repository root. CLI/model preparation defaults to CLT and
# deliberately does not load the GUI build's .env.local Xcode override.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
export MACOSX_DEPLOYMENT_TARGET=27.0

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  print -u2 "Apple developer directory not found: $DEVELOPER_DIR"
  return 1
fi

_pixelbooth_cli_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "$_pixelbooth_cli_sdk_version" != 27.* ]]; then
  print -u2 "PixelBooth requires the macOS 27 SDK; selected tools provide $_pixelbooth_cli_sdk_version."
  return 1
fi
