# Architecture

## Module map

| Module | Responsibility | Owns |
|--------|----------------|------|
| `PixelBoothCore` | Domain models: capture formats, provenance, acquisition-fidelity classification, mode selection, readiness state machine | Pure value types |
| `PixelBoothAdapters` | Pure-Swift sample-layout adapters (YUY2/UYVY/NV12/BGR/BGRA, 10-bit bi-planar) | Plane repacking only; never a conversion of meaningful samples |
| `PixelBoothJPEG` | JPEG segment parsing and metadata-only insertion | Marker-level byte exactness; rejects malformed input |
| `PixelBoothAVIF` | Lossless AVIF encode + verification via pinned libavif/libaom | Round-trip verification is mandatory before "valid" |
| `PixelBoothDepth` | Build-selected DepthAnythingV2 Core ML inference from a derived primary rendering | Validated model descriptor and actor-owned model; finite relative estimates, no archival primary conversion |
| `PixelBoothMetadata` | Metadata observation models, application XMP namespace, location acceptance policy | Provenance labeling (camera/host/app) |
| `PixelBoothCapture` | Capture backends: CoreMediaIO HAL (primary) and AVFoundation (fallback); discovery, configuration, frame delivery | Capture queues, CMIO stream state, generation tags |
| `PixelBoothLibrary` | Frame store, staging, journal, Photos-first save pipeline | Durable capture data |
| `PixelBoothApp` | SwiftUI presentation | No archival-path logic |
| `PixelBoothCAvif` | C shim over the pinned libavif 1.3.0 API | Boundary between Swift and pinned C libraries |

Dependency direction is strictly downward: App → Library/Capture → AVIF/JPEG/Metadata/Adapters → Core, with Library → Depth for local inference. Nothing points back up.

## Concurrency ownership

- `CaptureService` is an actor; session configuration and `startRunning`/`stopRunning` are called from the actor context, never from the main actor.
- `CMIOCaptureService` is the primary backend: an actor owning CMIO device/stream/format state. Mode selection happens at the HAL layer (`kCMIOStreamPropertyFormatDescription` is settable there, while AVFoundation pins device streams to their default on macOS 27 — TN3121 findings 3–4). Frames are delivered through the CMIO buffer queue and polled on a dedicated serial queue; both backends build `DeliveredFrame` values through one shared factory so generation tagging, freshness stamping, and sink delivery are identical. When the CMIO path is unestablishable for a device or mode (device absent from CMIO, format not advertised or not settable, stream start failure), the view model falls back to `CaptureService` — never running both backends on the same device at once, because same-process AVFoundation+CMIO mixing crashes the camera plugin on macOS 27.
- The video delegate runs on a dedicated serial capture queue. `forwardBuffer` is `nonisolated` and runs on the capture queue; it extracts immutable frame metadata and dispatches to sink queues.
- `SinkRegistry` and `SessionBox` are the two narrow, documented `@unchecked Sendable` exceptions (lock-protected dictionaries and one session reference). No other unsafe state exists; there is no blanket annotation.
- `FrameStore` is an actor; it owns retained `CMSampleBuffer`s for accepted photographs. Its active configuration (device + generation + frame interval) is explicit: `beginConfiguration` installs it after clearing retained frames, `invalidate` clears it, and `store` rejects every frame that does not match — including all frames while no configuration is active. Each `CaptureDelegate` captures its configuration's generation immutably at start, so a callback queued before reconfiguration carries the old tag and is rejected instead of being re-tagged from mutable global state. Freshness is the host-monotonic age of the frame at evaluation time: delivery stamps `hostMonotonicNanos` on the capture queue next to `hostWallClockISO`, so a stopped stream goes stale as time elapses instead of freezing at its last frame. At the shutter, selection is by media presentation timestamp within the active configuration — not callback/append order — so an out-of-order (H.264 decode-order) or delayed frame cannot displace newer content or resurrect a replaced configuration. `invalidateIfActive(deviceID:generation:)` drops retained frames when delivery stops, the device disconnects, or a session runtime error ends the stream; a delayed stop for an already-replaced stream is ignored.
- `ReadinessStateMachine` is a plain struct owned by `FrameStore`; state transitions are monotonic and derived from timestamps and frame rate, not callback counts.
- `SaveQueueActor` admits captures independently of its single active save pipeline: durable staging → waiting UUID FIFO → encoding → validating → adding → cleanup. Waiting payloads stay on disk; only the active source is loaded for processing. Admission checks the 200-entry journal bound and cumulative 512 MiB staging budget, including each source's recorded output/temporary-file reservation. Reservations are optional fields in the version-1 journal for compatibility; old sources' allowances are reconstructed individually when checking admission. One active AVIF encoding job; quitting finishes active work and leaves waiting captures for launch reconciliation. Cancellation and shutdown never delete recoverable captures.
- `AVIFEncodingWorker` serializes the complete primary/inference/auxiliary job, including across the estimator actor hop and overlapping Save Original requests. `DepthAnythingV2Estimator` owns its Core ML model and derived RGB buffers off the main actor. `DepthModel.json` selects the bundled model's names, geometry, output representation and interpretation; each inferred map carries the actual model provenance into AVIF metadata and the journal. Its output is quantized separately; the primary coding payloads, properties, metadata and native decoded channels are checked after attachment. The shutter-time disparity request is optional in persisted metadata for legacy compatibility. Configurations are bounded to 1,048,576 output samples. Enabled AVIF captures reserve an additional 4 MiB for output and atomic temporary storage.
- Enabled disparity outputs carry a validated `PortraitRenderIntent`: application-default simulated f/2.8 and a centered 10% × 10% normalized focus region. MWG Focus describes primary geometry; aperture describes the depth item. Neither is camera optics or subject-detection evidence. Source Exif stays verbatim and bounded, entity-disabled XMP merging gives source properties priority. Compatible source face regions can gain Focus; source Focus wins, and ambiguous/incompatible Regions remain unchanged. Public Core Image factory consumption is tested separately from manual Photos acceptance.
- `AVIFDisparity` quantizes in the model's raw range, then applies the versioned `portrait-relative-v1` native reconstruction range when a Portrait intent is present. This keeps renderer strength independent of the selected model's arbitrary scale without changing the coded gray8 plane. Descriptor and XMP preserve raw model bounds separately from virtual rendering units. Constant maps remain uniform; optional scale decoding preserves older journal descriptors' raw reconstruction. The chosen range has manual preference evidence on one capture, not measured metric accuracy or production Photos eligibility.
- `CaptureViewModel` reconfigures on camera or mode selection changes. A camera selection always invokes configuration for the newly selected device directly, independent of the mode-selection observer: a mode identity that matches across devices must never suppress reconfiguration. A selection that cannot be configured (device unavailable, no selectable mode) stops the previous stream instead of leaving it attached to a camera the picker no longer shows.

## Data flow

```
AVCaptureDevice (discovery, actual formats)
        │  modes ranked area-first/width-second, deterministic ties
        ▼
CaptureService.configure()   ← explicitly empty videoSettings (TN3121 native delivery)
        │  sample buffers tagged with configuration generation
        ▼
FrameIngest (FrameSink) → FrameStore (actor, retained buffers, freshness)
        │  newest fresh frame by presentation time in the active configuration
        ▼
CapturedCapture (+ FrameMetadataSnapshot at selection time, not encode time)
        │  durably staged first (capture.json + journal entry)
        ▼
SaveQueueActor
  ├─ MJPEG  → JPEG passthrough (metadata-only additions; source preserved)
  ├─ RGB/YUV → adapters → LosslessAVIF (libaom, speed 0) → decode-compare → validate
  └─ H.264  → VideoToolbox decode → lossless AVIF (same verification)
        ▼
PHAssetCreationRequest.addResource(.photo, fileURL:)  [Photos-first default]
        ▼
Journal: Capturing → Captured locally → Encoding → Validating → Adding to Photos → Saved
```

The preview surface (`AVCaptureVideoPreviewLayer`) is display-only and never feeds the archival encoder. `Mirror Preview` affects only the preview layer.

## XMP parsing policy

External XML entity resolution is disabled. Metadata additions use a
documented, versioned application namespace (`PixelBoothXMP.namespaceURI`);
source metadata is preserved verbatim where safe merging is impossible.

## Bounds discipline

All adapters use checked `bytesPerRow`/`rowCount` arithmetic and throw on
insufficient or inconsistent geometry (e.g. odd height for NV12) rather than
converting. Metadata parsing bounds-checks segment lengths before reads.

## Native dependency boundary

`Tools/PixelBoothCAvif` is the only C surface: three functions (version,
codec-name verification, image allocation). Swift code never touches libaom
internals, and the encoder's `codecChoice` is verified to be AOM after every
write — automatic codec substitution is impossible.

## Command-line frontend

`PixelBoothCLI` takes one photograph through the shared `CaptureFrameIngest`,
immutable-frame, metadata and `CaptureImageFinalizer` pipeline, writes the
result, prints its destination and exits. `SinglePhotoCapture` owns automatic
selection and the acquisition deadline. `StandaloneCaptureExporter` owns CLI
source staging, isolated journals and atomic file/stdout completion. It does
not request Photos access or import into Photos.

- Rank all eligible external USB camera/mode pairs using the existing order:
  pixel area, width, uncompressed before MJPEG before H.264, meaningful bit
  depth, chroma detail, maximum frame rate, then stable identifier.
  CLI color-detail ranking treats RGB's per-pixel components as equivalent to
  4:4:4; the comparator's default preserves the GUI's existing ranking. USB
  classification must survive unavailable identity-enrichment fields. Exclude
  virtual and Continuity cameras from automatic selection. If no external USB
  camera exists, use the built-in camera's highest supported mode. If a USB
  camera exists but cannot capture a supported representation, report failure.
- Select among modes the archival pipeline supports. Preserve the existing
  adapter restrictions and the current maximum of 12 meaningful bits per
  channel; 16-bit storage words do not establish 16-bit sample precision.
- After camera authorization, allow `--timeout SECONDS` (positive integer,
  default 10) for discovery, configuration,
  warm-up and acquisition of an acceptable immutable frame. Reuse freshness,
  generation and readiness checks; stop acquisition and exit nonzero on timeout.
  Stop the camera after retaining the photograph. Encoding, estimated-disparity
  model preparation and final validation are outside the acquisition deadline.
- Default to `~/Pictures`. Use `--output-dir DIRECTORY` for a generated filename
  and `--output FILE` for an explicit filename; reject conflicting arguments.
  Generated names must avoid collisions. Refuse to overwrite existing files
  by default and publish only fully validated files, atomically.
- Keep MJPEG as JPEG and uncompressed/decoded H.264 as AVIF. Reject an explicit
  filename extension that conflicts with the actual output representation.
  A successful file save prints only the absolute destination path and newline
  to stdout. `--output -` emits only standard base64 of the complete finalized
  image, without line wrapping, followed by a newline. Diagnostics use stderr;
  a broken pipe or incomplete output is a failure.
- Retain recoverable staged data and diagnostics on encoding, saving,
  cancellation or stdout failure, and print its recovery location to stderr.
  Isolate CLI journal ownership from GUI work and concurrent CLI processes.
  `--recover DIRECTORY` retries retained source/finalized data without camera
  access, preserving the original metadata and processing choice.
- CLI defaults for host location and estimated disparity are disabled and
  independent of GUI preferences. Preserve camera-supplied metadata. Any
  enabled disparity uses the same pinned model and verified auxiliary path.

`scripts/build_cli.sh` provides a separate CLT-compatible build path targeting
arm64 and macOS 27. Native dependency preparation also needs CMake, Ninja and
pkg-config. The CLI is an ordinary command-line executable with embedded
camera usage metadata and ad-hoc hardened-runtime signing with camera access.
It uses process filesystem permissions for explicit output paths. First-use
camera authorization may require interaction; the GUI has its own App Sandbox
entitlements and Photos destination policy.

Model preparation uses Xcode's `coremlcompiler` when available, with a CLT-built
helper fallback calling the public
[`MLModel.compileModel(at:)`](https://developer.apple.com/documentation/coreml/mlmodel/compilemodel(at:)-45ao6)
API. Compiled artifacts are persisted atomically and cached by source identity,
OS/Core ML runtime and toolchain/helper identity. Preparation retains the pinned
source checksum, license and model-interface checks and completes before
capture; there are no capture-time downloads. `build_cli.sh --with-disparity`
packages resources beside the executable for explicit `--estimated-disparity`.

- [ ] TODO: investigate exact 16-bit AVIF through `sato` sample transforms.
  Add native-channel reconstruction, metadata and decoder-compatibility
  validation before advertising support; keep this outside the initial CLI.
