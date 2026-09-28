# Build PixelBooth for macOS

You are working in an empty Git repository. Build a complete, runnable macOS camera application with the provisional name **PixelBooth**: a modern Photo Booth replacement for technically sophisticated users, focused on preserving camera-delivered image data and explaining exactly what was saved.

Implement the application, native dependencies, tests, and documentation. Do not stop at a plan, mockup, project skeleton, or simulated capture flow. Make reasonable decisions for unspecified details and document them. Do not reopen the settled product decisions below.

## 1. Platform and scope

Target **macOS 27.0 and later, Apple Silicon only, with a native SwiftUI interface**. Set the deployment target and architectures explicitly for the app and bundled native libraries. Do not lower the deployment target to accommodate the build machine.

Use Swift 6 with strict concurrency checking. Use AppKit integration only where appropriate for native macOS services or a capture-preview view; do not build an AppKit-first interface. No Electron, web UI, Catalyst, or cross-platform UI framework.

Ship a standalone `.app`. Bundle required native libraries; do not depend on Homebrew, command-line encoders, or system-installed codec libraries at runtime. Prefer an ordinary sandboxed application using public APIs, with only the necessary entitlements. No root access, driver replacement, private APIs, or weakened system protections. Make local development possible without a paid signing identity and document optional Developer ID signing/notarization separately.

The only final image outputs are **JPEG and AVIF**. Do not implement HEIC output, mixed-codec HEIF archives, embedded H.264 source tracks, alternative-image fallback arrangements, video recording, burst mode, filters, beautification, editing, or a Photos-library browser.

H.264 input, when available, is decoded and saved as lossless AVIF. It is not archived as compressed H.264.

## 2. Non-negotiable fidelity contract

Preserve image information, not USB packetization or buffer padding.

For native MJPEG/JPEG input, preserve the camera-provided JPEG image-coding data without recompression. For uncompressed RGB or YUV input, preserve every meaningful channel sample at its original bit depth and chroma sampling. For H.264 input, preserve the selected decoded picture's reconstructed channel samples without additional loss.

Repacking interleaved samples into planes, handling byte order, and removing unused storage bits are allowed when meaningful sample values remain unchanged. Changing subsampling, range, bit depth, or color interpretation is not allowed.

The archival path must not resize, crop, mirror, rotate sample arrays, denoise, sharpen, deinterlace, tone-map, clamp legal storage values, or pass YUV through RGB. Preserve source orientation and geometry as metadata where applicable. Reject unsupported representations rather than silently converting them.

Adding Exif/XMP may change file bytes. The JPEG promise is unchanged image-coding data, not whole-file byte identity. The AVIF promise is exact native-channel round-trip equality, not merely a visually identical rendering.

Never describe this as sensor RAW. Never present preservation after macOS delivery as proof of untouched USB-level acquisition.

## 3. Capture and acquisition provenance

Use AVFoundation as the initial capture backend, prioritizing UVC cameras. Discover actual devices and their actual formats. Support built-in and other AVFoundation cameras only with truthful capability and provenance reporting.

Investigate and use native delivery through `AVCaptureVideoDataOutput`. On macOS, distinguish an empty `videoSettings` dictionary requesting native-format delivery from `nil` requesting default uncompressed output. Verify this behavior against the installed SDK and inspect actual sample buffers rather than trusting configuration alone. Do not request BGRA merely because a preview example does so. [1]

Track separately: device-reported/negotiated format where accessible; actual delivered sample format; any decoding/conversion known to have occurred; and output representation. Do not label a camera as natively RGB just because macOS delivered RGB. Matching FourCCs alone does not verify the upstream acquisition path.

Build an explicit acquisition-fidelity classification. Mark native preservation verified only when evidence supports it. A known conversion that violates the selected native mode must fail that mode. When upstream behavior cannot be established, label it clearly as macOS-delivered preservation. Do not block capture solely because upstream behavior is unknown, and do not include an acknowledgment control in the app; explain this preservation boundary in the README. Do not silently substitute uncertain provenance for verified native preservation.

Read camera identity and additional USB/UVC information through supported APIs where accessible. Do not assume AVFoundation exposes every descriptor or control. Isolate optional identity enrichment from frame acquisition, and report unavailable fields as unavailable.

Keep stream configuration and blocking session operations off the main actor. Capture source samples and metadata independently of preview rendering. Retain or copy buffers correctly; never let later buffer reuse mutate an accepted photograph.

Handle device connection/disconnection, permission changes, session interruption, sleep/wake, and mode changes. Tag samples with a configuration generation so queued frames from an old configuration cannot become photographs in a new mode. Do not automatically activate another camera after disconnection.

## 4. Camera, mode, frame rate, and readiness

Provide a camera dropdown and a resolution/mode dropdown. A mode label should include dimensions, codec/FourCC, known bit depth and chroma sampling, and maximum frame rate; show unknown values honestly. Show the intended output path alongside the selection.

For a first selection or explicit reset, choose the supported mode with the largest pixel area; break area ties by greatest width. For otherwise identical dimensions, prefer uncompressed over MJPEG over H.264, then higher supported bit depth and chroma detail, then maximum frame rate, with a stable identifier as the final deterministic tie-breaker. These additional preferences must never override area and width.

Within the selected mode, request the **highest supported frame rate**. Use supported frame-duration controls, respect the advertised intervals, and show requested and measured rates separately. Do not silently lower resolution, precision, or chroma sampling to increase frame rate. Provide an advanced lower-frame-rate override. [2]

Remember explicit camera/mode/frame-rate choices per device. If a saved choice disappears, explain that and require selection rather than silently replacing it.

Start continuous streaming when the capture window is active and a camera is selected. Warm up in the final selected mode. Do not restart the stream or change frame rate at the shutter. Stop camera use when the capture window is closed; reopening it starts readiness assessment again.

Implement a readiness state machine. After startup, reconnection, or mode changes, exclude stale/configuration-mismatched frames. Use real exposure/focus/white-balance adjustment status where actually available. Otherwise use an explicitly labeled heuristic, not an invented claim of measured convergence.

Initial configurable heuristic defaults: at least eight fresh valid frames and 500 milliseconds since valid streaming began. Allow up to five seconds for available adjustment indicators to settle, then show “Still adjusting” with an explicit capture override. These numbers are product defaults, not assertions about all cameras. Do not classify a legitimately dark picture as invalid.

At the shutter event, select the newest complete, sufficiently fresh source frame already available. If stale, wait for a fresh frame with a bounded timeout. Derive freshness from timestamps and frame rate, not arbitrary callback counts. After an optional countdown, use its completion as the shutter event.

Do not automatically lock exposure, white balance, or focus after warm-up.

## 5. JPEG and AVIF encoding

### JPEG passthrough

Extract a complete JPEG from each supported native MJPEG sample. Preserve image-coding markers, tables, scan data, and entropy-coded payload without recompression. Metadata additions must use a tested metadata-only path.

Preserve source Exif, XMP, ICC, MakerNotes, and unknown metadata segments. Avoid conflicting duplicate Exif blocks or metadata rewriting that breaks MakerNote offsets. Where safe merging is impossible, preserve the original metadata and put additional application observations into an appropriate XMP representation rather than corrupting source fields.

Do not decode to a bitmap and create a new JPEG. Reject malformed or incomplete input with a recoverable error instead of silently repairing image data.

### AVIF

Use pinned **libavif + libaom**, with an in-process native bridge. Explicitly select the AOM encoder; never allow automatic codec substitution. Configure:

    codecChoice = AVIF_CODEC_CHOICE_AOM
    quality = AVIF_QUALITY_LOSSLESS
    qualityAlpha = AVIF_QUALITY_LOSSLESS, when meaningful alpha exists
    speed = 0

Confirm that the pinned versions enable genuine AV1 lossless coding. Do not equate a generic “maximum quality” UI setting with verified losslessness. Keep speed zero even when encoding is slow. [3]

For RGB, write a sample-preserving identity-matrix, full-range, 4:4:4 representation at the original supported bit depth. Directly populate the planes with G, B, R in the corresponding Y, U, V slots. Do not run a conventional RGB-to-YCbCr conversion or an unnecessary floating-point round trip. Preserve meaningful alpha and its association; do not mistake padding for alpha or silently premultiply/unpremultiply samples. [4]

For YUV, preserve the original channel samples, subsampling, bit depth, range, and representable chroma positioning. Repack YUY2/UYVY or deinterleave NV12 directly; never route these through RGB. Preserve samples outside nominal video range when valid at the source bit depth.

Implement and test acquisition adapters for JPEG/MJPEG, 8-bit YUY2/UYVY, NV12 full/limited range, common 8-bit RGB/BGR/BGRA layouts, and 10-bit bi-planar YUV when exposed. Implement the canonical AVIF core for supported 8/10/12-bit RGB and monochrome/YUV 4:2:0, 4:2:2, and 4:4:4. Advertise a concrete input layout only after its adapter passes tests. Unknown, interlaced, Bayer, floating-point, or otherwise unsupported layouts must not be silently normalized.

Decode every newly encoded AVIF and compare native-channel samples before declaring archival validation successful. Use an independently implemented decoder in the test suite as an additional check. Do not compare only RGB renderings of YUV images.

### H.264 input

Use a continuously maintained VideoToolbox decompression session, or an equivalent verified system-delivered decoded path. Maintain decoder dependencies, parameter-set changes, and presentation timestamps; do not attempt to decode an arbitrary selected compressed frame in isolation. Select the picture by presentation time, not decoder callback order. [5]

Preserve reconstructed sample representation and color metadata through AVIF encoding. Reject paths that silently reduce precision or alter chroma sampling. Discarding warm-up pictures from capture eligibility must not break decoder dependencies. Save no H.264 source stream in the output.

## 6. Color, geometry, ICC, and HDR

Collect metadata from sample-buffer attachments, pixel-buffer attachments, stream/format descriptions, and embedded source metadata. Snapshot the metadata applicable to the selected picture, not whatever happens to be current when encoding completes.

Preserve available color primaries, transfer characteristics, matrix coefficients, range, chroma location, original ICC bytes, mastering-display information, content-light-level information, and applicable HDR/dynamic metadata. Preserve source pixel aspect ratio, clean aperture, and orientation without modifying the sample array.

Use standard codec/container properties where available; storing a string in XMP is not a substitute for a standard property needed for correct rendering. Ensure output descriptors describe the stored representation—for example, RGB identity coding must not carry a contradictory YCbCr matrix. Retain original descriptors in provenance when necessary.

Do not assume sRGB, BT.709, full/limited range, HDR luminance values, or a chroma location just to fill a missing field. Distinguish explicit source values, documented format semantics, and unknown values. Use unspecified/absent signaling where legal. If an essential interpretation cannot be represented without guessing, fail explicitly rather than inventing it.

Preserve otherwise unrepresentable source metadata in a documented, versioned archival form inside the image, with its source and raw payload where available. Report limitations in standard-reader interpretation. Do not silently discard it. Do not invent ICC profiles, gain maps, or HDR metadata.

The preview may perform display color management and scaling, but its rendered surface must never feed the archival encoder.

## 7. Exif, XMP, time, location, and provenance

Save all available source Exif and XMP, including unknown tags/namespaces, without replacing them with a small whitelist. Use standard fields only when their semantics match. Add a documented, versioned application XMP namespace for technical information and provenance.

Separate camera-provided data, host observations, and application-generated technical data. Preserve camera make/model where genuinely reported, USB vendor/product IDs, manufacturer/product strings, serial number when exposed, and other accessible camera information with accurate labels. Preserve conflicting source values rather than silently choosing a guessed truth.

Do not turn vendor-ID lookup results into camera-reported make, generic device revisions into firmware versions, gain into ISO, or focus position into focal length. A control read near the shutter is a timestamped host observation, not automatically per-frame Exif.

Preserve existing camera timestamps. Record host-observed capture time for the selected frame, including timezone offset and justified subsecond precision. Correlate media/monotonic time with wall-clock time explicitly; do not use encoding/import completion time or describe a callback timestamp as sensor exposure time. Fill missing standard capture-time fields from the documented host estimate and record that provenance.

Include a user-visible **Include Location** preference, initially offered enabled but requiring authorization before acquiring or adding host coordinates. Use Core Location and record observation timestamp, age at capture, and reported accuracy. Start with a configurable maximum age of 60 seconds. Reject invalid/stale observations and invalid altitude; omit unavailable information without delaying the shutter. Never invent zero coordinates or claim the location method was GPS without evidence. [6]

Host location is the Mac's location, not necessarily a remote camera's location. Preserve existing camera location separately. Make clear that disabling host-location additions does not scrub metadata already supplied by a camera. Explain that preserved originals may include location and device identifiers. No analytics, account requirement, telemetry, or application-controlled image uploads.

Store capture UUID, application/backend/library versions, actual capture format, encoder settings, metadata provenance, and canonical sample hash where appropriate. Define canonical hash byte order and channel layout and exclude padding. Store the finalized whole-file hash in the save journal, not self-referentially inside that file.

## 8. Photos-first saving and recovery

Default to saving the completed original directly into the **System Photo Library**, without a Save dialog. The product owner has tested the intended ordinary AVIF output in Photos; keep AVIF as the target and add regression coverage rather than silently substituting HEIC/JPEG.

Use PhotoKit original-resource creation with the finished JPEG/AVIF file, not an NSImage/CGImage round trip. Set Photos creation date/location consistently with the metadata resolution policy, while retaining source/host provenance. Use the minimum authorization actually supported on macOS 27; do not assume iOS-specific access behavior. [7]

Private staging is allowed and required for reliability. Durably store the immutable source snapshot and metadata before treating a capture as safely queued. Encode, validate, finalize atomically, import, and clean up only after confirmed success. Do not promise iCloud synchronization merely because local import succeeded.

Maintain a versioned crash-recoverable journal with capture UUIDs and explicit states. Bound both memory and disk usage; refuse additional captures with a clear explanation when capacity is exhausted rather than dropping accepted captures or changing encoding settings.

Distinguish **Capturing → Captured locally → Encoding → Validating → Adding to Photos → Saved**, with recoverable failure states. Display no invented percentage when a stage lacks progress reporting. The shutter animation must not imply completion.

On denied permission, unavailable library, import failure, or disk exhaustion, preserve recoverable data. Offer Retry and Save Original…; allow an explicit folder destination as an alternative to Photos. Use security-scoped access where needed and write the same finalized JPEG/AVIF, never a different representation.

Handle ambiguous import completion after a crash without blindly creating duplicates. Retain journal identifiers and reconcile where authorization permits; otherwise expose the uncertainty and require an explicit retry. Do not claim perfect idempotency without evidence.

Add an opt-in integration test using PhotoKit resource retrieval to compare the retained original with the exact finalized file submitted. This may require read permission and must not force ordinary users to grant library-browsing access just for routine captures. [8]

## 9. Native interface

Build a focused, resizable SwiftUI window with the full-frame camera preview, camera/mode dropdowns, shutter button, readiness/status text, and a compact pending-save indicator. Use native controls, SF Symbols, system typography, light/dark appearances, keyboard navigation, and VoiceOver labels.

Provide **View > Mirror Preview** as a persisted menu toggle. It affects only the preview and never saved samples, Exif orientation, or AVIF transforms. Default it off. Show the full frame without cropping by default; offer fit and 100% inspection.

Support Space to capture when it does not conflict with a focused control, and an optional Off/3-second/10-second countdown. Provide native settings for destination, location, and advanced frame-rate/readiness preferences.

Add an expandable inspector showing device identity; negotiated versus delivered format; acquisition-fidelity classification; dimensions, depth, subsampling, range, and color/HDR information; requested/measured frame rate; output path; encoder settings; metadata sources; and verification/save results. Show unavailable information as unknown, not zero or fabricated defaults.

Detect and report relevant system camera effects where public APIs expose them. Never report an unavailable effect status as “off.” Keep the primary UI simple; expose detail progressively rather than making the application a wall of diagnostics.

## 10. Architecture and dependency discipline

Separate capture discovery/configuration, immutable captured-frame ownership, sample-layout adapters, metadata collection/serialization, JPEG preservation, AVIF encoding/verification, location, Photos/files, durable queue, and SwiftUI presentation. Share well-defined models rather than a single giant controller.

Use clear actor/queue ownership. Do not solve concurrency warnings with blanket `@unchecked Sendable` or unsafe nonisolated mutable state. Document any narrow necessary exception. Use checked size/stride arithmetic and strict bounds when handling device data and metadata. Disable external XML entity resolution when parsing XMP.

Keep preview/capture responsive while libaom runs at speed zero. Start with one active AVIF encoding job and a bounded thread budget; apply backpressure without reducing fidelity. Handle cancellation and shutdown without deleting recoverable captures.

Pin native dependencies to releases or immutable commits with checksums and reproducible arm64 builds. Keep the Swift/C boundary small and testable. Record licenses/notices and dependency versions. Do not fetch arbitrary moving branches during ordinary builds. Do not bundle tools solely to shell out for every photograph.

## 11. Required tests and acceptance criteria

Create fixtures and automated tests before relying on live-camera behavior. At minimum, cover these groups:

**Selection and timing:** area-first/width-second ranking, deterministic ties, remembered selections, maximum-rate negotiation, readiness timeout/override, stale frames, mode-generation rejection, disconnect/reconnect, and presentation-order selection for H.264.

**Image fidelity:** random and edge-value RGB/YUV fixtures; supported 8/10/12-bit depths and chroma layouts; odd dimensions where legal; padded/noncontiguous strides; packed/bi-planar adapters; high-bit-depth packing; channel ordering; meaningful alpha; full/limited range including superblack/superwhite samples. Compare native samples exactly after AVIF decoding. Verify libaom selection, actual lossless settings, and speed zero.

**JPEG preservation:** compare all image-coding segments and scan payload before/after metadata insertion. Include unknown APP segments, source Exif/XMP/ICC, MakerNotes, long metadata, and malformed input. Metadata addition must not trigger recompression.

**Metadata and preview isolation:** preserve source and unknown fields; verify color/HDR properties, orientation, timezone/subseconds, absent/stale/invalid location, source-versus-host conflicts, and provenance. Feed identical fixtures through mirrored/unmirrored preview settings and prove archival samples and orientation are unchanged.

**Persistence and failure:** crash/relaunch recovery at each save stage, failed/ambiguous imports, retries, storage exhaustion, queue backpressure, permission changes, and cleanup. Confirm that accepted captures are not silently lost and that reported success reflects actual destination completion.

**Real integration:** an actual launchable arm64 app, real camera enumeration/capture, representative Photos imports, and optional original-resource hash comparison. Record OS/SDK/hardware/camera/mode/library versions for integration evidence.

Mocks and synthetic sources are for tests/development only. They must not be the default application behavior or evidence of real-camera/Photos compatibility. Mark hardware-dependent tests **Not run** when the environment lacks the hardware or permissions; do not count them as passed. Do not mark core required formats unsupported merely to make the test suite green.

## 12. Repository, workflow, and completion

Begin by inspecting the environment and available SDK/toolchain. Use current primary documentation and installed headers, not invented macOS 27 APIs. If the SDK, signing setup, camera, or Photos access is unavailable, continue implementing everything possible and report the precise validation gap. Do not quietly change the product target.

Work in executable milestones: first the project/native build and fidelity fixtures; then real capture and encoding; then metadata/Photos/recovery; then the finished SwiftUI interface and full test pass. Build and test throughout. Do not stop after the diagnostic milestone.

Commit a usable Xcode project/workspace with shared schemes, any local Swift packages, dependency lock information, reproducible bootstrap/build/test scripts, automated tests and fixtures, privacy descriptions/entitlements, third-party notices, and documentation. Fresh-checkout build instructions must not depend on uncommitted local Xcode configuration or unexplained filesystem paths.

Provide `README.md`, `AGENTS.md` preserving these invariants, architecture notes, a supported-format/capability matrix, a manual hardware/Photos test plan, and an honest known-limitations document. Add CI suitable for the required toolchain where available; distinguish toolchain unavailability from a successful test run.

At completion, report exactly what was implemented, build/run/test commands, tests actually run and their results, remaining hardware-dependent checks, and known deviations. Do not claim that the application builds, preserves native UVC data, or round-trips through Photos unless those specific claims were tested.

The completion goal is a working native application with real capture, validated JPEG/AVIF preservation, metadata, and a recoverable Photos-first save path—not merely a scaffold or a report about how one could build it.

## Primary implementation references

Verify these against the SDK and dependency versions you actually use.

[1] Apple, AVCaptureVideoDataOutput.videoSettings and TN3121:
https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings
https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput

[2] Apple, activeVideoMinFrameDuration:
https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration

[3] libavif public encoder API:
https://github.com/AOMediaCodec/libavif/blob/main/include/avif/avif.h

[4] libavif channel/identity representation implementation:
https://github.com/AOMediaCodec/libavif/blob/main/src/reformat.c

[5] Apple, VTDecompressionSession:
https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession

[6] Apple, CLLocation:
https://developer.apple.com/documentation/corelocation/cllocation

[7] Apple, PhotoKit original-resource creation:
https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:fileurl:options:)

[8] Apple, PHAssetResourceManager:
https://developer.apple.com/documentation/photos/phassetresourcemanager
