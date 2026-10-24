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
