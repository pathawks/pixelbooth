# PixelBooth

A modern Photo Booth replacement for macOS, focused on **preserving camera-delivered
image data** and **explaining exactly what was saved**.

- Native SwiftUI interface, Apple Silicon only, macOS 27.0+
- Swift 6, strict concurrency checking
- AVFoundation capture (`AVCaptureVideoDataOutput`), prioritizing UVC cameras
- **JPEG passthrough**: native MJPEG samples are archived with the camera's own
  image-coding data — markers, tables, and scan payload — never recompressed
- **Lossless AVIF** for the layouts listed as supported in
  [`docs/CAPABILITY_MATRIX.md`](docs/CAPABILITY_MATRIX.md), encoded in-process
  by pinned libavif + libaom at speed 0 and verified by exact native-channel
  round-trip comparison
- Photos-first saving with durable staging, a crash-recoverable journal, and
  recoverable failure states

## Quick start

Requirements:
- Apple Silicon Mac
- macOS 27.0 SDK and full Xcode 27 for app builds. The headless test runner can
  be built with Command Line Tools, but they cannot load the SwiftUI macro plugin
  required by the app target.
- Camera permission when running the app

```sh
scripts/validate.sh       # debug builds + automated tests; does not update the .app
scripts/build_app.sh      # create/replace the release build/PixelBooth.app
open build/PixelBooth.app
```

First run asks for camera permission. PixelBooth requests Photos add-only access
when you first save; if access was previously denied, the app explains how to
enable it in System Settings. Default saving destination is the System Photo
Library.

After rebuilding, quit any running copy and reopen `build/PixelBooth.app` so
macOS uses the updated app permission configuration. Failed and retained
captures have Dismiss controls; dismissal keeps their local recovery data.
Restore, Retry, and Save Original… remain available where the capture's
representation supports them.

You can take another photo while an earlier capture is encoding or saving.
Waiting captures are stored privately on disk and shown as **Captured locally**;
one save pipeline processes them in order. The queue keeps waiting identifiers
in memory and loads each source when its turn arrives. Staging is bounded to
512 MiB, including reservations for final images and temporary files, and 200
unfinished or retained captures. When capacity is exhausted, new captures are
refused with an explanation. Quitting finishes the active save and leaves waiting
captures recoverable for the next launch.

## Build and test commands

| Command | Purpose |
|---------|---------|
| `scripts/validate.sh` | Strict lint, pinned native deps, debug app/test builds, automated tests; does not assemble `.app` |
| `scripts/build_app.sh` | Strict lint, release build, and assembly; replaces `build/PixelBooth.app` |
| `swift format lint --strict --recursive Sources Tests Tools` | Check formatting and Swift style rules |
| `swift build --product PixelBooth` | Executable only |
| `swift run --skip-build PixelBoothTestRunner` | Automated test suite |
| `scripts/fetch_deps.sh` | Re-fetch/rebuild libavif 1.3.0 + libaom 3.13.1 (checksum-verified) |

## Project-local Xcode selection

The build scripts leave the machine-wide `xcode-select` setting unchanged. If
it points to Command Line Tools, copy `.env.local.example` to `.env.local` and
set `DEVELOPER_DIR` to the full Xcode Developer directory. The scripts load
that file only when `DEVELOPER_DIR` is not already set in the environment.

## The fidelity contract, in short

- Native MJPEG/JPEG input → the camera's JPEG image-coding data is preserved
  byte-for-byte; only metadata additions may change file bytes.
- Uncompressed RGB/YUV input → every meaningful channel sample is preserved at
  its original bit depth and chroma sampling (AVIF lossless, verified by exact
  round-trip, not visual similarity).
- H.264 input has a VideoToolbox decode-to-snapshot path. The synthetic 8-bit
  acceptance fixture passes on macOS 27.0.1; live-camera behavior and
  preservation of other H.264 precisions, sampling and ranges remain
  unverified. The compressed source is never stored as an image archive.
- No resizing, cropping, mirroring, rotation, denoise, sharpen, tone-mapping,
  deinterlacing, or YUV-through-RGB on the archival path. Ever.
- Unsupported representations are rejected with an explicit error, not
  silently normalized.

### Frames delivered by macOS

PixelBooth preserves the image representation delivered by macOS. A known
conversion that conflicts with the selected camera mode is rejected. When the
upstream path cannot be established, the capture is labeled
`macDeliveredUnknownUpstream`; that uncertainty does not block capture. Matching
format identifiers alone do not prove untouched USB-level acquisition, and
PixelBooth is not sensor RAW. The saved evidence records what was delivered and
what is known about its origin.

The format matrix distinguishes known FourCC facts from formats that have a
tested archival adapter. In particular, `v210` is packed 10-bit 4:2:2 and is
not currently supported by the archival path.

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
