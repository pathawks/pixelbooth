# PixelBooth

A modern Photo Booth replacement for macOS, focused on **preserving camera-delivered
image data** and **explaining exactly what was saved**.

- Native SwiftUI interface, Apple Silicon only, macOS 27.0+
- Swift 6, strict concurrency checking
- AVFoundation capture (`AVCaptureVideoDataOutput`), prioritizing UVC cameras
- **JPEG passthrough**: native MJPEG samples are archived with the camera's own
  image-coding data — markers, tables, and scan payload — never recompressed
- **Lossless AVIF** for uncompressed RGB/YUV and decoded H.264 input, encoded
  in-process by pinned libavif + libaom at speed 0, verified by exact
  native-channel round-trip comparison
- Photos-first saving with durable staging, a crash-recoverable journal, and
  recoverable failure states

## Quick start

Requirements:
- Apple Silicon Mac
- macOS 27.0 SDK (Command Line Tools are sufficient for command-line builds; the
  full Xcode 27 toolchain is required to open the package as a project and run
  XCTest-based UI tests)
- Camera permission when running the app

```sh
scripts/build.sh          # build everything + run the test suite
scripts/build_app.sh      # build release and assemble build/PixelBooth.app
open build/PixelBooth.app
```

First run asks for camera permission. Default saving destination is the System
Photo Library (Photos add-only authorization).

## Build and test commands

| Command | Purpose |
|---------|---------|
| `scripts/build.sh` | Fetch/build pinned native deps, build all targets, run test runner |
| `scripts/build_app.sh` | Release build + assemble `build/PixelBooth.app` |
| `swift build --product PixelBooth` | Executable only |
| `swift run --skip-build PixelBoothTestRunner` | Automated test suite |
| `scripts/fetch_deps.sh` | Re-fetch/rebuild libavif 1.3.0 + libaom 3.13.1 (checksum-verified) |

## The fidelity contract, in short

- Native MJPEG/JPEG input → the camera's JPEG image-coding data is preserved
  byte-for-byte; only metadata additions may change file bytes.
- Uncompressed RGB/YUV input → every meaningful channel sample is preserved at
  its original bit depth and chroma sampling (AVIF lossless, verified by exact
  round-trip, not visual similarity).
- H.264 input → decoded via VideoToolbox and saved as lossless AVIF; the source
  stream is not stored.
- No resizing, cropping, mirroring, rotation, denoise, sharpen, tone-mapping,
  deinterlacing, or YUV-through-RGB on the archival path. Ever.
- Unsupported representations are rejected with an explicit error, not
  silently normalized.
- This is not sensor RAW, and preservation after macOS delivery is not proof of
  untouched USB-level acquisition. The inspector says exactly what was
  preserved and on what evidence.

## Documentation

- `docs/ARCHITECTURE.md` — module map, concurrency ownership, dependency rules
- `docs/CAPABILITY_MATRIX.md` — supported formats and evidence status
- `docs/MANUAL_TEST_PLAN.md` — hardware/Photos verification steps
- `docs/KNOWN_LIMITATIONS.md` — honest deviations and gaps
- `AGENTS.md` — invariants preserving the product decisions
- `vendor/dependencies.md` — pinned native dependency details and licenses

## Repository layout

```
Sources/PixelBoothCore/        Domain models, mode selection, readiness
Sources/PixelBoothAdapters/    Pure-Swift sample-layout adapters
Sources/PixelBoothJPEG/        JPEG segment parsing + metadata-only writer
Sources/PixelBoothAVIF/        Lossless AVIF encoder/verifier (libavif bridge)
Sources/PixelBoothMetadata/    Exif/XMP/ICC/HDR/location metadata models
Sources/PixelBoothCapture/     AVFoundation discovery/configuration/delivery
Sources/PixelBoothLibrary/     Staging, journal, Photos-first save pipeline
Sources/PixelBoothApp/         SwiftUI application
Tools/PixelBoothCAvif/         C shim over the pinned libavif API
Tests/PixelBoothTestRunner/    Self-contained automated test suite
Support/                       Info.plist, entitlements, privacy strings
vendor/                        Pinned dependency info, checksums, notices
scripts/                       Bootstrap/build/test/bundle scripts
```
