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
- **Estimated disparity** in AVIF using DepthAnythingV2 Small, running locally
  through Core ML; the primary image remains sample-exact
- Photos-first saving with durable staging, a crash-recoverable journal, and
  recoverable failure states

## Quick start

Requirements:
- Apple Silicon Mac
- macOS 27.0 SDK and full Xcode 27 for app builds. The headless test runner can
  be built with Command Line Tools, but they cannot load the SwiftUI macro plugin
  required by the app target.
- Python 3.9 or newer for model preparation (Xcode's `/usr/bin/python3` works)
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
| `scripts/fetch_depth_model.sh` | Fetch, verify, and compile the selected pinned DepthAnythingV2 Core ML model |

## Estimated disparity in AVIF

Settings > Disparity > **Include Estimated Disparity in AVIF** is initially
enabled. The choice is saved with each accepted capture, so changing it does
not change photographs already queued. Older staged captures without that
choice retain their original behavior. JPEG passthrough captures remain JPEG.

The checked-in build choices are Apple's Apache-2.0 Core ML conversions of
**DepthAnythingV2 Small F16** (default) and **Small F32**. Inference runs locally
during encoding, once per photograph. No model download or network access
happens during capture. Build scripts fetch the pinned model files with
SHA-256 verification and compile them with Xcode.

Choose a public build variant explicitly:

```sh
PIXELBOOTH_DEPTH_VARIANT=SmallF16 scripts/build_app.sh
PIXELBOOTH_DEPTH_VARIANT=SmallF32 scripts/build_app.sh
```

The same selection works with `scripts/validate.sh` and
`scripts/fetch_depth_model.sh`. CI validates both Small variants. An explicit
variant takes precedence over the automatic local override.

A Git-ignored `depth-model.local.json` can supply a personal pinned model,
including Large, without changing the checked-in catalog. When present,
ordinary `scripts/build_app.sh` and `scripts/validate.sh` use that override.
The local file contains the model's immutable source, checksums, license and
actual Core ML interface, using `{"schemaVersion": 1, "model": ...}` with the
same model-entry schema as [`scripts/depth-models.json`](scripts/depth-models.json).
Model weights, compiled models and the local
configuration stay out of Git. Large weights use CC-BY-NC-4.0; a personal
Large build carries that model's license rather than claiming the Small
model's Apache license.

The resulting app contains one selected model, its `DepthModel.json`
descriptor, and its full license. Switching variants replaces those resources
together. The runtime verifies the selected model's feature names, geometry,
output representation and version; saved disparity metadata and the inspector
identify the model actually used. Invalid selections fail explicitly.

Inference uses a separate 8-bit sRGB rendering of the verified primary AVIF,
with alpha composited on black, stretched to the selected model's full input
field without cropping or mirroring (518×392 for Apple's Small models). This
can distort aspect ratio for the estimate. The primary archival planes never
pass through that rendering and are never resized. The auxiliary map retains
the selected model's output geometry and maps over the full primary image.

The map is an **application-generated relative inverse-depth estimate**, with
larger values nearer. It is neither measured camera depth nor a distance in
meters. The model's floating-point predictions are normalized using their
minimum/maximum and quantized to 8 bits. A hidden monochrome AV1 auxiliary
image stores those prepared samples losslessly, with a depth `auxC` property
and `auxl` reference to the primary image. Its XMP records
`NativeFormat=fdis`, `StoredFormat=L008` (numeric pixel-format identifiers on
disk), relative accuracy, model identity, normalization bounds, and the
application-generated origin. Apple's float/integer endpoint fields allow
ImageIO to reconstruct native Float32 disparity. This does not restore precision
discarded by quantization or mean the file stores exact Float32 predictions.

With a Portrait rendering intent, the native endpoints use the fixed
`portrait-relative-v1` range (approximately 1.777344–6.09375). This application
rendering scale prevents arbitrary model output ranges from exaggerating blur
and applies equally to Small and Large outputs. The source model bounds and
quantization remain recorded separately, so the prepared samples can still be
reconstructed in their original relative scale. A constant estimate stays
uniform at the rendering minimum. This range was preferred in one manual
capture comparison; it is an artistic default, not measured physical distance
or camera calibration. Attachments without a rendering intent retain the
source reconstruction range; older journal descriptors retain that behavior.

Validation decodes the prepared disparity plane and compares every sample;
it also checks that attaching the map preserves the primary image's coding
data and decoded native channels. Inference or auxiliary validation failures
retain the staged source and expose a recoverable encoding failure. Processing
remains serialized and staging reserves additional space for the map.

The synthetic inference fixture also checks native `fdis` reconstruction through
ImageIO and `AVDepthData`, including relative accuracy and every reconstructed
sample. Enabled AVIF captures also carry an application-selected rendering
intent: a centered 10% × 10% MWG `Focus` region on the primary image and
`depthBlurEffect:SimulatedAperture=2.8` on the disparity item. Their versioned
provenance identifies application defaults, not detected subjects, camera
autofocus, or the camera's physical aperture. Primary focus dimensions refer
to the saved image, independent of model geometry and preview mirroring.
Existing source Exif is retained verbatim; source XMP properties win conflicts
when the application fields are merged. Compatible source face regions are
retained alongside the generated Focus region; an existing source Focus takes
precedence. Ambiguous region structures or mismatched source dimensions are
retained without adding a default region or guessing a coordinate conversion.

Native Core Image checks verify that its depth-blur factory reads the saved
focus and aperture defaults. These checks do not establish Apple Photos
Portrait recognition or real-world estimation accuracy. Photos remains a
separate manual check. We do not copy an opaque iPhone `REND` block or Apple
MakerNote, invent camera calibration, or declare unmeasured depth quality to
claim Portrait support.

## Project-local Xcode selection

The build scripts leave the machine-wide `xcode-select` setting unchanged. If
it points to Command Line Tools, copy `.env.local.example` to `.env.local` and
set `DEVELOPER_DIR` to the full Xcode Developer directory. The scripts load
that file only when `DEVELOPER_DIR` is not already set in the environment.

## The fidelity contract, in short

Captures with metadata that PixelBooth cannot map to standard output fields
are still retained. Supported JPEG/AVIF output includes the original attachment
archive in application XMP; Capture Status shows a metadata warning and offers
**Metadata Report…**. After a successful Photos import, captures with reports
keep their local image, source snapshot and report until explicitly discarded.
Reports stay local and may contain device identifiers and included location
metadata; exporting or sharing one is a deliberate user action. If the base
color interpretation cannot be encoded faithfully, the source and report remain
durably saved on the Mac while final image export needs additional support.

A missing YUV matrix is reported even when an ICC profile is present. The
image still saves with an unspecified matrix and retained diagnostic evidence.
Bounded observations from earlier frames in the same stream are retained
separately; they do not override the shutter frame's color interpretation.
The [Brio color investigation](docs/BRIO_COLOR_INVESTIGATION.md) records why
USB descriptors, advertised formats, and delivered frames must be distinguished.

Camera identity prefers AVFoundation, then USB descriptor strings, then an
attributed USB vendor/product ID map. Missing manufacturer values are omitted
from generated Exif. USB identity enrichment never opens the USB device or
changes acquisition settings. Standard UVC identifier conventions are matched
against location, VID and PID in IORegistry; unavailable or ambiguous matches
remain unavailable. Numeric lookup results are application-generated identity,
not camera-provided Exif.

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
Sources/PixelBoothDepth/       Local Core ML relative-disparity estimation
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
