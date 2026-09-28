# Architecture

## Module map

| Module | Responsibility | Owns |
|--------|----------------|------|
| `PixelBoothCore` | Domain models: capture formats, provenance, acquisition-fidelity classification, mode selection, readiness state machine | Pure value types |
| `PixelBoothAdapters` | Pure-Swift sample-layout adapters (YUY2/UYVY/NV12/BGR/BGRA, 10-bit bi-planar) | Plane repacking only; never a conversion of meaningful samples |
| `PixelBoothJPEG` | JPEG segment parsing and metadata-only insertion | Marker-level byte exactness; rejects malformed input |
| `PixelBoothAVIF` | Lossless AVIF encode + verification via pinned libavif/libaom | Round-trip verification is mandatory before "valid" |
| `PixelBoothMetadata` | Metadata observation models, application XMP namespace, location acceptance policy | Provenance labeling (camera/host/app) |
| `PixelBoothCapture` | AVFoundation discovery, configuration, `AVCaptureVideoDataOutput` delivery | Capture queue, session, generation tags |
| `PixelBoothLibrary` | Frame store, staging, journal, Photos-first save pipeline | Durable capture data |
| `PixelBoothApp` | SwiftUI presentation | No archival-path logic |
| `PixelBoothCAvif` | C shim over the pinned libavif 1.3.0 API | Boundary between Swift and pinned C libraries |

Dependency direction is strictly downward: App → Library/Capture → AVIF/JPEG/Metadata/Adapters → Core. Nothing points back up.

## Concurrency ownership

- `CaptureService` is an actor; session configuration and `startRunning`/`stopRunning` are called from the actor context, never from the main actor.
- The video delegate runs on a dedicated serial capture queue. `forwardBuffer` is `nonisolated` and runs on the capture queue; it extracts immutable frame metadata and dispatches to sink queues.
- `SinkRegistry` and `SessionBox` are the two narrow, documented `@unchecked Sendable` exceptions (lock-protected dictionaries and one session reference). No other unsafe state exists; there is no blanket annotation.
- `FrameStore` is an actor; it owns retained `CMSampleBuffer`s for accepted photographs. Frames are tagged with the configuration `generation` so a queued frame from an old configuration cannot become a photograph in a new mode.
- `ReadinessStateMachine` is a plain struct owned by `FrameStore`; state transitions are monotonic and derived from timestamps and frame rate, not callback counts.
- `SaveQueueActor` serializes the save pipeline: staging → encoding → validating → adding → cleanup. One active AVIF encoding job; cancellation and shutdown never delete recoverable captures.

## Data flow

```
AVCaptureDevice (discovery, actual formats)
        │  modes ranked area-first/width-second, deterministic ties
        ▼
CaptureService.configure()   ← explicitly empty videoSettings (TN3121 native delivery)
        │  sample buffers tagged with configuration generation
        ▼
FrameIngest (FrameSink) → FrameStore (actor, retained buffers, freshness)
        │  newest sufficiently fresh frame at the shutter event
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
