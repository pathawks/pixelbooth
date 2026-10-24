# AGENTS.md — invariants for PixelBooth

This file preserves the settled product decisions and engineering invariants.
Do not reopen them in future work.

## Product target

- macOS 27.0 and later, Apple Silicon only, native SwiftUI. Deployment target
  and arm64 architecture are set explicitly; never lower the deployment target
  to accommodate a build machine.
- Swift 6, strict concurrency. AppKit integration only for native services and
  the capture-preview surface; never AppKit-first.
- Standalone sandboxed `.app`, public APIs only, ordinary entitlements
  (camera, Photos add-only, location, user-selected files). No root, no private
  APIs, no weakened protections, no Electron/Catalyst/web UI.
- Local development without a paid signing identity (ad-hoc signing);
  optional Developer ID signing/notarization documented separately.

## Output formats (settled)

- Final image outputs are **JPEG and AVIF only**.
- No HEIC output, mixed-codec HEIF, embedded H.264 source tracks, video
  recording, burst mode, filters, beautification, editing, or Photos-library
  browser.
- H.264 input is decoded and saved as lossless AVIF — never archived as
  compressed H.264.

## Fidelity contract (non-negotiable)

- Preserve image information, not USB packetization or buffer padding.
- MJPEG: preserve the camera JPEG image-coding data without recompression.
- Uncompressed RGB/YUV: preserve every meaningful channel sample at the
  original bit depth and chroma sampling.
- H.264: preserve the decoded picture's reconstructed samples.
- Repacking interleaved samples into planes, byte-order handling, and removing
  unused storage bits are allowed when meaningful sample values are unchanged.
  Changing subsampling, range, bit depth, or color interpretation is not.
- The archival path never resizes, crops, mirrors, rotates sample arrays,
  denoises, sharpens, deinterlaces, tone-maps, clamps legal storage values, or
  passes YUV through RGB.
- Reject unsupported representations rather than silently converting.
- Adding Exif/XMP may change file bytes; the JPEG promise is unchanged
  image-coding data, not whole-file byte identity. The AVIF promise is exact
  native-channel round-trip equality, not visual similarity.
- Never describe this as sensor RAW. Never present preservation after macOS
  delivery as proof of untouched USB-level acquisition.

## Acquisition

- AVFoundation is the initial backend; `AVCaptureVideoDataOutput` with an
  explicitly empty (non-nil) `videoSettings` dictionary requests native-format
  delivery. Verify against the installed SDK and inspect actual sample buffers.
- Track separately: device-reported format, delivered format, known
  conversions, output representation. Matching FourCCs alone do not prove the
  upstream acquisition path.
- The acquisition-fidelity classification is evidence-driven. A known
  conversion that violates the selected native mode must fail that mode.
  Unestablishable upstream behavior is labeled "macOS-delivered preservation"
  and recorded as uncertain provenance. This uncertainty does not gate capture;
  it must never be presented as verified native acquisition. The README explains
  this preservation boundary to users.
- Identity enrichment (USB IDs, strings) is isolated from frame acquisition;
  unavailable fields are reported unavailable.
- Stream configuration stays off the main actor. Accepted photographs own
  retained/copied buffers; later buffer reuse must not mutate an accepted
  photograph. Samples are tagged with a configuration generation; queued
  frames from an old configuration never become photographs in a new mode.
- No automatic camera activation after disconnection.

## Camera, mode, readiness (settled)

- Mode labels: dimensions, codec/FourCC, known bit depth and chroma sampling,
  maximum frame rate — unknown values shown honestly.
- First selection/reset: largest pixel area, then greatest width, then
  uncompressed > MJPEG > H.264, then higher depth/chroma detail, then higher
  max frame rate, then stable identifier. Area and width always dominate.
- Request the highest supported frame rate within the selected mode; never
  silently lower resolution/precision/chroma for frame rate; advanced
  lower-rate override available.
- Remember explicit choices per device; a vanished choice is explained and
  re-selection required, never silently replaced.
- Stream starts when the window is active, warms up in the final selected
  mode, is not restarted at the shutter; camera stops when the window closes.
- Readiness: exclude stale/mismatched frames; use real adjustment indicators
  where actually available; otherwise an explicitly labeled heuristic
  (defaults: ≥8 fresh frames, ≥500 ms, ≤5 s adjusting-wait with override).
  A legitimately dark picture is never "invalid".
- Shutter selects the newest complete sufficiently fresh frame; stale → wait
  bounded. No auto-lock of AE/AF/AWB after warm-up.

## Encoding (settled)

- JPEG: complete-JPEG extraction, no bitmap decode, metadata-only additions,
  source metadata preserved; conflicts resolved in favor of the source, with
  additional observations in XMP.
- AVIF: pinned libavif + libaom, explicit `AVIF_CODEC_CHOICE_AOM`,
  `quality = AVIF_QUALITY_LOSSLESS`, `qualityAlpha` lossless when alpha
  exists, `speed = 0`. Every new AVIF is decoded and compared in native
  channels before validation success.
- Adapters and the canonical AVIF core are tested per layout; a layout is
  advertised only after its adapter passes tests. Unknown/interlaced/Bayer/
  floating-point layouts are never silently normalized.

## Metadata, time, location (settled)

- Prefer meaningful AVFoundation make/model, then matched USB descriptor
  strings, then explicitly attributed USB vendor/product ID lookups. Preserve
  raw API observations separately; generated Exif omits placeholders. Persist
  the USB IDs, strings, observation time and association method at the shutter.
- Save all available source Exif/XMP including unknown tags/namespaces; add a
  documented, versioned application XMP namespace for technical/provenance
  data. Separate camera-provided, host-observed, and application-generated
  data. Preserve conflicting source values.
- Do not turn vendor-ID lookups into camera-reported make, device revisions
  into firmware versions, gain into ISO, or focus position into focal length.
  Control reads near the shutter are timestamped host observations.
- Preserve existing camera timestamps; record host-observed capture time with
  timezone offset and justified subsecond precision; correlate media time
  with wall clock explicitly. Encoding/import completion time is not capture
  time, and a callback timestamp is not sensor exposure time.
- Include Location preference: initially offered enabled, requires
  authorization before acquiring coordinates; observation timestamp, age at
  capture, and reported accuracy recorded; max age configurable (default 60 s);
  invalid/stale/altitude rejected; nothing invented (no zero coordinates, no
  "GPS" claim without evidence); the shutter never waits on location.
- Host location is the Mac's location, not a remote camera's. Disabling host
  location does not scrub camera-supplied metadata. No analytics, accounts,
  telemetry, or app-controlled uploads.

## Saving and recovery (settled)

- Default destination: System Photo Library, no Save dialog, original-resource
  creation with the finalized JPEG/AVIF file — never an NSImage/CGImage round
  trip. Minimum authorization (macOS 27); no iOS-specific assumptions.
- AVIF is the target in Photos; add regression coverage rather than silently
  substituting HEIC/JPEG.
- Private staging is required: durably store the immutable source snapshot and
  metadata before a capture is "safely queued"; encode/validate/finalize
  atomically; import, then clean up only after confirmed success. No iCloud
  promises.
- Versioned crash-recoverable journal with capture UUIDs and explicit states;
  bounded memory and disk; clear refusal when capacity is exhausted.
- Stage display: Capturing → Captured locally → Encoding → Validating →
  Adding to Photos → Saved, with recoverable failures; no invented percentages;
  shutter animation never implies completion.
- Denied permission/import failure/disk exhaustion → preserve recoverable
  data; offer Retry and Save Original… (explicit folder destination; same
  finalized file, security-scoped where needed).
- Ambiguous import completion after a crash is reconciled via journal
  identifiers where authorization permits; otherwise expose uncertainty and
  require explicit retry. No unproven idempotency claims.
- Optional integration test compares the retained original with the exact
  finalized file via PhotoKit resource retrieval; must not force library
  access for routine captures.

## Interface (settled)

- Focused, resizable window: full-frame preview (no crop by default; fit and
  100% inspection), camera/mode dropdowns, shutter, readiness status,
  pending-save indicator. Native controls, SF Symbols, system typography,
  light/dark, keyboard navigation, VoiceOver labels.
- View > Mirror Preview: persisted menu toggle, preview-only, never affects
  saved samples, Exif orientation, or AVIF transforms. Default off.
- Space to capture when not conflicting with a focused control; optional
  Off/3s/10s countdown. Native settings for destination, location, advanced
  frame-rate/readiness preferences.
- Expandable inspector: device identity; negotiated vs delivered format;
  fidelity classification; geometry/depth/subsampling/range/color/HDR info;
  requested vs measured frame rate; output path; encoder settings; metadata
  sources; verification/save results. Unknown is shown as unknown — never zero
  or fabricated. System camera effects reported only from public APIs; never
  report an unavailable effect status as "off".

## Engineering discipline (settled)

- Separate modules: capture discovery/configuration, immutable frame
  ownership, sample adapters, metadata, JPEG preservation, AVIF
  encoding/verification, location, Photos/files, durable queue, presentation.
  Shared well-defined models; no giant controller.
- Clear actor/queue ownership; no blanket `@unchecked Sendable` and no unsafe
  nonisolated mutable state; document any narrow necessary exception.
- Checked size/stride arithmetic and strict bounds for device data and
  metadata; external XML entity resolution disabled for XMP parsing.
- Preview may be color-managed/scaled for display but never feeds the
  archival encoder.
- One active AVIF encoding job and a bounded thread budget; backpressure
  without fidelity loss; cancellation and shutdown never delete recoverable
  captures.
- Pinned native dependencies with checksums, reproducible arm64 builds,
  recorded licenses/notices; no arbitrary branch fetches during ordinary
  builds; no bundling shell-out tools for every photograph.

## Formatting and lint (mandatory)

- All Swift files under `Sources`, `Tests`, and `Tools` must comply with the
  checked-in `.swift-format` configuration. The required check is
  `swift format lint --strict --recursive Sources Tests Tools`.
- This check is part of the build pipelines and must not be bypassed: do not
  skip it, exclude files, add suppressions, or weaken the configuration to
  make violations pass. Format code with `swift format format` and resolve the
  findings before completing a change.

## Testing discipline (settled)

- Fixtures and automated tests come before live-camera reliance.
- Required groups: selection/timing; image fidelity (random + edge-value,
  supported depths/layouts, odd dims, padded strides, packed/bi-planar,
  high-bit-depth, alpha, full/limited range with superblack/superwhite —
  exact native-sample comparison after AVIF decode); JPEG preservation
  (segments and scan payload, unknown segments, MakerNotes, malformed input);
  metadata/preview isolation; persistence/failure recovery; real integration.
- Mocks/synthetic sources are for tests/development only — never default app
  behavior or compatibility evidence. Hardware-dependent tests are reported
  "Not run" when hardware/permissions are absent; never counted as passed.
  Never mark core required formats unsupported merely to go green.

## Validation honesty (settled)

- Report exactly what was implemented, build/run/test commands, tests actually
  run and results, remaining hardware-dependent checks, and known deviations.
- Never claim the app builds, preserves native UVC data, or round-trips through
  Photos unless those specific claims were tested. Distinguish toolchain
  unavailability from successful test runs.
