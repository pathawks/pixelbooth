#!/bin/zsh
# Fetch and build pinned native dependencies (libavif 1.3.0 + libaom 3.13.1)
# as arm64 static libraries against the macOS 27.0 SDK.
# No arbitrary branches are fetched; only the pinned archives above are used.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CACHE="$ROOT/.vendor-cache"
BUILD="$ROOT/vendor/build"
mkdir -p "$CACHE" "$BUILD"

AVIF_URL="https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.3.0.tar.gz"
# Gitiles +archive output is not byte-stable; use AOMedia's release tarball.
AOM_URL="https://storage.googleapis.com/aom-releases/libaom-3.13.1.tar.gz"
AVIF_SHA="0a545e953cc049bf5bcf4ee467306a2f113a75110edf59e61248873101cd26c1"
AOM_SHA="19e45a5a7192d690565229983dad900e76b513a02306c12053fb9a262cbeca7d"

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
CLANG_VERSION=$(clang --version | head -n 1)
CLANGXX_VERSION=$(clang++ --version | head -n 1)
CMAKE_VERSION=$(cmake --version | head -n 1)
NINJA_VERSION=$(ninja --version)

AOM_CONFIG=$(cat <<EOF
version=3.13.1
sha256=$AOM_SHA
target=arm64-apple-macos27.0
sdk=$SDK_PATH
cflags=$COMMON_CFLAGS
cc=$CLANG_VERSION
cxx=$CLANGXX_VERSION
cmake=$CMAKE_VERSION
ninja=$NINJA_VERSION
build=Release
tests=0 docs=0 tools=0 examples=0 werror=0
av1_decoder=1 av1_encoder=1
EOF
)
AOM_CONFIG_ID=$(printf '%s' "$AOM_CONFIG" | shasum -a 256 | awk '{print $1}')
AOM_STAMP="$BUILD/aom/.pixelbooth-build-config"
AOM_LIBRARY="$BUILD/aom/libaom.a"
AOM_HEADERS="$BUILD/aom-install/include/aom"
AOM_CACHE_VALID=false
if [[ -f "$AOM_STAMP" && "$(<"$AOM_STAMP")" == "$AOM_CONFIG_ID" \
  && -s "$AOM_LIBRARY" && -s "$AOM_HEADERS/aom.h" \
  && -s "$AOM_HEADERS/aom_codec.h" && -s "$AOM_HEADERS/aom_encoder.h" ]]; then
  AOM_CACHE_VALID=true
fi

if [[ "$AOM_CACHE_VALID" == true ]]; then
  echo "OK (cached): pinned libaom archive, headers, and configuration"
else
  rm -rf "$BUILD/aom-src" "$BUILD/aom" "$BUILD/aom-install"
  mkdir -p "$BUILD/aom-src"
  tar xzf "$CACHE/aom.tgz" -C "$BUILD/aom-src" --strip-components=1
  cmake -S "$BUILD/aom-src" -B "$BUILD/aom" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DENABLE_TESTS=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 \
    -DENABLE_WERROR=0 \
    -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 \
    -DCMAKE_INSTALL_PREFIX="$BUILD/aom-install"
  cmake --build "$BUILD/aom" --config Release
  cmake --install "$BUILD/aom" --config Release
  [[ -s "$AOM_LIBRARY" && -s "$AOM_HEADERS/aom.h" && -s "$AOM_HEADERS/aom_encoder.h" ]]
  printf '%s' "$AOM_CONFIG_ID" > "$AOM_STAMP"
fi

AVIF_CONFIG=$(cat <<EOF
version=1.3.0
sha256=$AVIF_SHA
target=arm64-apple-macos27.0
sdk=$SDK_PATH
cflags=$COMMON_CFLAGS
cc=$CLANG_VERSION
cmake=$CMAKE_VERSION
ninja=$NINJA_VERSION
build=Release static-only
apps=0 tests=0 examples=0
libyuv=OFF libsharpyuv=OFF
codec_aom=SYSTEM encode=ON decode=ON
pinned_aom=$AOM_CONFIG_ID
pkg-config-path=$BUILD/aom only
EOF
)
AVIF_CONFIG_ID=$(printf '%s' "$AVIF_CONFIG" | shasum -a 256 | awk '{print $1}')
AVIF_STAMP="$BUILD/avif/.pixelbooth-build-config"
AVIF_LIBRARY="$BUILD/avif/libavif.a"
AVIF_HEADERS="$BUILD/avif-install/include/avif"
AVIF_CACHE_VALID=false
if [[ -f "$AVIF_STAMP" && "$(<"$AVIF_STAMP")" == "$AVIF_CONFIG_ID" \
  && -s "$AVIF_LIBRARY" && -s "$AVIF_HEADERS/avif.h" ]]; then
  AVIF_CACHE_VALID=true
fi

if [[ "$AVIF_CACHE_VALID" == true ]]; then
  echo "OK (cached): pinned static libavif archive, headers, and configuration"
else
  rm -rf "$BUILD/avif-src" "$BUILD/avif" "$BUILD/avif-install"
  mkdir -p "$BUILD/avif-src"
  tar xzf "$CACHE/avif.tgz" -C "$BUILD/avif-src"
  # libavif's SYSTEM AOM finder consults pkg-config. Restrict its search to
  # libaom's generated metadata and ignore any caller/Homebrew PKG_CONFIG_PATH.
  env PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$BUILD/aom" \
    cmake -S "$BUILD/avif-src/libavif-1.3.0" -B "$BUILD/avif" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
      -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
      -DBUILD_SHARED_LIBS=OFF \
      -DAVIF_BUILD_APPS=0 -DAVIF_BUILD_TESTS=0 -DAVIF_BUILD_EXAMPLES=0 \
      -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF \
      -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_ENCODE=ON -DAVIF_CODEC_AOM_DECODE=ON \
      -DAOM_INCLUDE_DIR="$BUILD/aom-install/include" \
      -DAOM_LIBRARY="$AOM_LIBRARY" \
      -DCMAKE_INSTALL_PREFIX="$BUILD/avif-install"
  cmake --build "$BUILD/avif" --config Release
  cmake --install "$BUILD/avif" --config Release
  [[ -s "$AVIF_LIBRARY" && -s "$AVIF_HEADERS/avif.h" ]]
  printf '%s' "$AVIF_CONFIG_ID" > "$AVIF_STAMP"
fi

echo "Dependencies ready:"
ls -l "$AOM_LIBRARY" "$AVIF_LIBRARY"
