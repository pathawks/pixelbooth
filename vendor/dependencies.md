# Pinned native dependencies

These libraries are built from pinned releases and linked into the app.
The app never depends on Homebrew or system-installed codec libraries at runtime.

| Component | Version | Source | SHA-256 (tarball) |
|-----------|---------|--------|-------------------|
| libavif | 1.3.0 | https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.3.0.tar.gz | `0a545e953cc049bf5bcf4ee467306a2f113a75110edf59e61248873101cd26c1` |
| aom (libaom, AV1 encoder) | 3.13.1 | https://storage.googleapis.com/aom-releases/libaom-3.13.1.tar.gz | `19e45a5a7192d690565229983dad900e76b513a02306c12053fb9a262cbeca7d` |

## Build-selected DepthAnythingV2 Core ML model

Apple's Small F16 and F32 packages are pinned to the
[`apple/coreml-depth-anything-v2-small` revision
`cfef6f6f2a70783dedc0bfae40cecbc2052285d3`](https://huggingface.co/apple/coreml-depth-anything-v2-small/tree/cfef6f6f2a70783dedc0bfae40cecbc2052285d3).
The checked-in catalog, `scripts/depth-models.json`, contains only these two
Apache-2.0 selections. `PIXELBOOTH_DEPTH_VARIANT=SmallF16` is the default;
`SmallF32` selects the other official package. An explicit variant bypasses
the automatic Git-ignored `depth-model.local.json` override. An explicit
`PIXELBOOTH_DEPTH_OVERRIDE` path can select a custom descriptor; setting both
explicit selectors is rejected as ambiguous.

`scripts/fetch_depth_model.sh` delegates to the standard-library Python helper
`scripts/depth_model.py`. Every package file, archive and license has a pinned
SHA-256. Custom archive extraction rejects unsafe paths and links. Source
model/weights checksums are verified independently after extraction. Compilation
uses the selected Xcode and SDK; cache stamps include the complete selection
and toolchain, and generated files are checked against a digest manifest.

Prepared selections live under `vendor/build/depth/`; `selected` resolves to
one complete configuration directory. App assembly and validation resolve that
directory from that preparation invocation so the model, `DepthModel.json` and
license remain a matched set even if another process changes the selected
link. A preparation lock serializes shared-cache writes. Failed preparation retains
the previous selection and fails the build. Model sources, compiled models and
personal overrides are not checked into Git.

The pinned F16 model specification SHA-256 is
`44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042`;
the weights SHA-256 is
`fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed`.
The F32 specification SHA-256 is
`dfd7fd461ab2544f4951e757a59d878d6af93b5544541ed534329d84e958f0c9`;
its weights SHA-256 is
`6b02236f9b6c8c4694904f89c0fc84c3b6175cde43f9f918f77948708c36b58d`.
Manifest and license hashes are also pinned in the catalog. Compiled model bytes
are toolchain-dependent. The chosen model is bundled as `PixelBoothDepth.mlmodelc`;
its identity, geometry, source hashes and license identifier are recorded in
`DepthModel.json`. The full selected license is bundled as
`ThirdPartyNotices/DepthModel-LICENSE`.

Both actual Small model descriptions specify 518×392 RGB input and a 518×392
half-float image output, including the F32 package. Their graphs normalize
nonnegative inverse-depth predictions by their per-image maximum. Custom models
can instead declare bounded image Float32 or strided Float16/Float32 array
outputs and raw nonnegative relative values. The runtime checks the declared
interface against the loaded model and refuses a mismatch. These are relative
estimates, not metric depth. App preprocessing and quantization are documented
in the README. Large weights carry CC-BY-NC-4.0; a local Large override must
provide that license rather than inheriting the Small model's Apache license.

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
exactly (see `Tests/PixelBoothTestRunner/JPEGAndAVIFSuites.swift`). A build of
libaom or libavif that fails lossless round-trip for a supported layout makes
that layout unsupported at runtime.

## Build recipe

`scripts/fetch_deps.sh` downloads the pinned archives, verifies SHA-256
checksums, and builds arm64 static libraries against the macOS 27.0 SDK. Its
cache stamps include the pinned versions and checksums, selected archive and
headers, SDK path, deployment target, architecture, compiler/CMake/Ninja
versions, and codec/build options. An absent archive, installed header, or
matching stamp triggers a rebuild:

- aom: CMake, Release, `ENABLE_TESTS=0`, `ENABLE_DOCS=0`, `ENABLE_TOOLS=0`,
  `ENABLE_EXAMPLES=0`, arm64 (`AOM_TARGET_CPU=arm64` via the arm64 SDK triple),
  `-mmacosx-version-min=27.0`, `-arch arm64`. Build output:
  `vendor/build/aom/libaom.a` (all AV1 encoder/decoder sources, static).
- libavif: CMake, Release, `BUILD_SHARED_LIBS=OFF`, `AVIF_BUILD_APPS=0`,
  `AVIF_BUILD_TESTS=0`, `AVIF_BUILD_EXAMPLES=0`,
  `AVIF_CODEC_AOM=SYSTEM` (against the aom built above), and libyuv/sharpyuv
  disabled. The consumed
  `libavif.a` is the static archive linked by SwiftPM; `libaom.a` supplies its
  codec symbols.

During libavif configuration, `PKG_CONFIG_PATH` is cleared and
`PKG_CONFIG_LIBDIR` points only at the generated metadata in
`vendor/build/aom`. This lets libavif's system-codec finder identify the pinned
libaom while preventing unrelated Homebrew or host `.pc` files (such as AOM
metadata that adds libvmaf) from entering include or link settings. The app
links only the pinned static archives and has no runtime pkg-config or codec
dependency.

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
