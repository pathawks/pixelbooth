# Source after changing to the repository root, before invoking Apple build tools.
# An explicitly exported value takes precedence over this repository's .env.local.
if [[ -z "${DEVELOPER_DIR:-}" && -f ".env.local" ]]; then
  source ".env.local"
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR
fi

_pixelbooth_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$_pixelbooth_developer_dir" == */CommandLineTools ]]; then
  print -u2 "PixelBooth app builds require full Xcode; Command Line Tools cannot load SwiftUIMacros."
  print -u2 "Set DEVELOPER_DIR in .env.local or export it for the build command."
  return 1
fi

if [[ ! -d "$_pixelbooth_developer_dir" ]]; then
  print -u2 "Apple developer directory not found: $_pixelbooth_developer_dir"
  return 1
fi

_pixelbooth_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "$_pixelbooth_sdk_version" != 27.* ]]; then
  print -u2 "PixelBooth requires the macOS 27 SDK; selected Xcode provides $_pixelbooth_sdk_version."
  return 1
fi
