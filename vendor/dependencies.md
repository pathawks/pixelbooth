# Pinned native dependencies

These libraries are built from pinned releases and linked into the app.
The app never depends on Homebrew or system-installed codec libraries at runtime.

| Component | Version | Source | SHA-256 (tarball) |
|-----------|---------|--------|-------------------|
| libavif | 1.3.0 | https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.3.0.tar.gz | `0a545e953cc049bf5bcf4ee467306a2f113a75110edf59e61248873101cd26c1` |
| aom (libaom, AV1 encoder) | 3.13.1 | https://aomedia.googlesource.com/aom/+archive/v3.13.1.tar.gz | `f353e511e15f58631c6180c0924d54496b5bcd59e174e9862db6ddef0eb9e0e4` |

## Why these versions

- **libavif 1.3.0** exposes the `quality`/`qualityAlpha` encoder API
  (`AVIF_QUALITY_LOSSLESS == 100`) and `AVIF_CODEC_CHOICE_AOM`, which PixelBooth
  requires for verified lossless AVIF encoding. Its lossless path is exercised by
  upstream tests (`tests/gtest/aviflosslesstest.cc`) and by PixelBooth's own
  round-trip suite.
- **libaom 3.13.1** is a stable release of the reference AV1 encoder. Lossless
  encoding (quantizer 0) is fully supported for 8/10/12-bit input. It is ABI
  compatible with 3.13.0.

Lossless claims are never taken from documentation alone: PixelBooth's test
suite encodes fixtures and decodes them back, comparing native-channel samples
exactly (see `Tests/PixelBoothTests/AVIFRoundTripTests.swift`). A build of
libaom or libavif that fails lossless round-trip for a supported layout makes
that layout unsupported at runtime.

## Build recipe

`scripts/fetch_deps.sh` downloads the pinned archives, verifies SHA-256
checksums, and builds arm64 static libraries against the macOS 27.0 SDK:

- aom: CMake, Release, `ENABLE_TESTS=0`, `ENABLE_DOCS=0`, `ENABLE_TOOLS=0`,
  `ENABLE_EXAMPLES=0`, arm64 (`AOM_TARGET_CPU=arm64` via the arm64 SDK triple),
  `-mmacosx-version-min=27.0`, `-arch arm64`. Build output:
  `vendor/build/aom/libaom.a` (all AV1 encoder/decoder sources, static).
- libavif: CMake, Release, `AVIF_BUILD_APPS=0`, `AVIF_BUILD_TESTS=0`,
  `AVIF_CODEC_AOM=SYSTEM` (against the aom built above),
  `AVIF_BUILD_MANPAGES=0`. Only libavif's core `src` is built
  (encoder/decoder/reformat), statically linked with `libaom.a`.

The Swift module `Tools/PixelBoothCAvif` wraps the C API via a module map and a
tiny shim (`Shim.c`) so Swift code can use the pinned API surface.

## Checksum verification

`scripts/fetch_deps.sh` fails the build if a downloaded archive does not match
the SHA-256 above, or if the archives are absent and cannot be downloaded. A
local cache directory (`.vendor-cache`, git-ignored) may be pre-populated to
make fresh checkouts hermetic.

## Licenses

- libavif: BSD-2-Clause (`vendor/notices/libavif-LICENSE`)
- libaom: BSD-2-Clause + additional IP-style disclaimers
  (`vendor/notices/aom-LICENSE`)
- NV12/YUY2 adapter code, PixelBooth's Swift and C sources: project license
  (see `LICENSE`).
- Full third-party notices are aggregated in `vendor/notices/NOTICES.md`.
