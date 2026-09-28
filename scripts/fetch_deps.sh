#!/bin/zsh
# Fetch and build pinned native dependencies (libavif 1.3.0 + libaom 3.13.1)
# as arm64 static libraries against the macOS 27.0 SDK.
# No arbitrary branches are fetched; only the pinned archives above are used.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CACHE=".vendor-cache"
BUILD="$ROOT/vendor/build"
mkdir -p "$CACHE" "$BUILD"

AVIF_URL="https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.3.0.tar.gz"
AOM_URL="https://aomedia.googlesource.com/aom/+archive/v3.13.1.tar.gz"
AVIF_SHA="0a545e953cc049bf5bcf4ee467306a2f113a75110edf59e61248873101cd26c1"
AOM_SHA="f353e511e15f58631c6180c0924d54496b5bcd59e174e9862db6ddef0eb9e0e4"

fetch() {
  local url="$1" dest="$2" expected="$3"
  if [[ -f "$dest" ]] && shasum -a 256 "$dest" | awk '{print $1}' | grep -q "$expected"; then
    echo "OK (cached): $dest"
    return
  fi
  echo "Downloading $url"
  curl -sL --fail --max-time 300 -o "$dest" "$url"
  local actual
  actual=$(shasum -a 256 "$dest" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "CHECKSUM MISMATCH for $dest: $actual != $expected" >&2
    exit 1
  fi
}

fetch "$AVIF_URL" "$CACHE/avif.tgz" "$AVIF_SHA"
fetch "$AOM_URL" "$CACHE/aom.tgz" "$AOM_SHA"

export MACOSX_DEPLOYMENT_TARGET=27.0
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
COMMON_CFLAGS="-target arm64-apple-macos27.0 -isysroot $SDK_PATH -mmacosx-version-min=27.0"

# --- aom ---
if [[ ! -f "$BUILD/aom/libaom.a" ]]; then
  rm -rf "$BUILD/aom-src" "$BUILD/aom"
  mkdir -p "$BUILD/aom-src"
  tar xzf "$CACHE/aom.tgz" -C "$BUILD/aom-src"
  cmake -S "$BUILD/aom-src" -B "$BUILD/aom" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DENABLE_TESTS=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 \
    -DENABLE_GCOV=0 -DENABLE_WERROR=0 \
    -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 \
    -DCMAKE_INSTALL_PREFIX="$BUILD/aom-install"
  cmake --build "$BUILD/aom" --config Release
  cmake --install "$BUILD/aom" --config Release
else
  echo "OK (cached): $BUILD/aom/libaom.a"
fi

# --- libavif ---
if [[ ! -f "$BUILD/avif/libavif.a" ]]; then
  rm -rf "$BUILD/avif-src" "$BUILD/avif"
  mkdir -p "$BUILD/avif-src"
  tar xzf "$CACHE/avif.tgz" -C "$BUILD/avif-src"
  cmake -S "$BUILD/avif-src/libavif-1.3.0" -B "$BUILD/avif" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DAVIF_BUILD_APPS=0 -DAVIF_BUILD_TESTS=0 -DAVIF_BUILD_GTESTS=0 \
    -DAVIF_BUILD_MANPAGES=0 -DAVIF_BUILD_EXAMPLES=0 \
    -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF \
    -DAVIF_CODEC_AOM=SYSTEM \
    -DAOM_INCLUDE_DIR="$BUILD/aom-install/include" \
    -DAOM_LIBRARY="$BUILD/aom/libaom.a" \
    -DCMAKE_INSTALL_PREFIX="$BUILD/avif-install"
  cmake --build "$BUILD/avif" --config Release
  cmake --install "$BUILD/avif" --config Release
else
  echo "OK (cached): $BUILD/avif/libavif.a"
fi

echo "Dependencies ready:"
ls -l "$BUILD/aom/libaom.a" "$BUILD/avif/libavif_internal.a"
