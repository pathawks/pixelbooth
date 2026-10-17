# Manual hardware and Photos test plan

These checks require physical hardware and TCC permissions. Record actual
results (OS/SDK/hardware/camera/mode/library versions) when run; report
"Not run" otherwise. Never count a hardware-dependent check as passed.

## Environment capture (record before each run)

- OS build (`sw_vers`), SDK version (`xcrun --sdk macosx --show-sdk-version`)
- Hardware model (`sysctl -n hw.model`)
- Camera: name, USB vendor/product ID, exposed serial number
- Selected mode (dimensions/FourCC/depth/chroma/rate) and measured frame rate
- libavif/libaom versions

## 1. Real camera enumeration

1. Launch `build/PixelBooth.app`.
2. Grant camera permission when prompted.
3. Confirm the Camera dropdown lists actual connected devices (built-in and UVC).
4. Confirm the Mode dropdown lists actual advertised formats with dimensions,
   FourCC, known depth/chroma, and max frame rate; unknown values must display
   as unknown, not zero.

Expected: real devices, honest mode labels.

## 2. Native delivery verification (TN3121)

1. Select a UVC camera exposing MJPEG.
2. Capture a photo; open the inspector.
3. Verify negotiated vs delivered format is reported, the acquisition-fidelity
   classification is `nativePreserved` only when evidence supports it, and any
   known conversion is listed.
4. If upstream behavior cannot be established, verify the inspector and saved
   provenance label the frame as macOS-delivered with unknown upstream behavior,
   while a valid capture remains available without an acknowledgment gate.

Expected: classification matches the actual evidence.

## 3. JPEG passthrough on hardware

1. Capture a photo in MJPEG mode.
2. Compare all image-coding segments and scan payload between the staged
   snapshot and the saved file.
3. Add unknown APP segments and MakerNotes to the camera stream (if exposed)
   and confirm they survive verbatim.

Expected: image-coding data identical; only metadata additions differ.

## 4. Uncompressed capture → lossless AVIF

1. Select a supported uncompressed mode from `CAPABILITY_MATRIX.md` (such as
   NV12/420v, 24BG, or x420 if exposed). Do not count v210 as supported; it is
   packed 10-bit 4:2:2 and currently has no archival adapter.
2. Capture; confirm the saved file is AVIF, matrix identity for RGB, range
   signaled as stored.
3. Verify the journal shows Encoding → Validating success.

Expected: lossless round-trip verified; no invented settings.

## 5. H.264 input

The automated 8-bit encoded-fixture-to-AVIF acceptance test passed on macOS
27.0.1 on October 12, 2026. This supersedes the older session-creation failure
(`-12911`) for that fixture. Live input and other source representations still
require separate fidelity acceptance.

1. Select an H.264 mode.
2. Confirm warm-up pictures excluded from eligibility do not break decoder
   dependencies.
3. Confirm the picture is selected by presentation time.
4. Confirm the saved file contains no H.264 source stream.

## 6. Photos-first saving

Quit any older app copy and reopen the newly assembled `build/PixelBooth.app`.
Confirm first authorization offers add-only access. If previously denied,
check the app's recovery message and the Photos privacy entry in System
Settings; record whether the rebuilt app appears and prompts correctly.

1. With Photos add-only authorization, capture and confirm the asset appears
   in the System Photo Library with creation date matching the resolved
   policy.
2. Confirm no Save dialog appears.
3. Optional: enable the integration check (requires read authorization) and
   compare the retained original against the exact finalized file via
   `PHAssetResourceManager`.
4. Confirm no iCloud-sync claim is displayed merely because local import
   succeeded.

## 7. Failure and recovery

1. Deny Photos permission → capture data preserved; Retry and Save Original…
   offered; explicit folder destination writes the same finalized file.
2. Simulate disk exhaustion (fill staging) → capture refused with a clear
   explanation; accepted captures not silently lost; encoding settings
   unchanged.
3. Crash at each stage (Capturing/Encoding/Validating/Adding), relaunch, and
   confirm the journal reconciles without blind duplicates; ambiguous cases
   exposed with explicit retry.
4. Dismiss each failed stage and an existing retained capture. Confirm they
   leave the active lists and remain under Dismissed captures after relaunch.
   Restore one, then Retry or Save Original where supported. An ambiguous
   retry must still require duplicate confirmation.

## 8. Disconnect / sleep / mode changes / stalled delivery

1. Unplug the UVC camera mid-stream: app must not auto-activate another camera,
   the shutter must disable, and no frame from the stopped stream may be
   captured (including immediately after unplugging).
2. Stop delivery without a disconnect (e.g. camera held by another process):
   the shutter must not accept the last frame after its freshness window
   (1.5× the configured frame interval) has elapsed.
3. Sleep and wake: session recovers; stale frames excluded.
4. Change mode: configuration generation increments; queued old-mode frames
   rejected, and the freshness window follows the newly selected mode's rate.
5. Switch between two connected cameras: the mode list and preview must update
   and the session must reconfigure for the newly selected device. In
   particular, with two devices exposing the same descriptive mode label, the
   capture stream must move to the new device rather than remain on the
   previous camera.

## 9. Interface checks

1. View > Mirror Preview persists across relaunch; default off.
2. Space captures when no focused control conflicts.
3. Countdown Off/3s/10s; completion is the shutter event.
4. VoiceOver labels on shutter/dropdowns/status; keyboard navigation works.
5. 100% inspection shows uncropped pixels; fit shows the full frame.
6. At the minimum window size, populate several failed and retained captures.
   Confirm the status area scrolls and every recovery action remains reachable.

## 10. Captures waiting for encoding

1. Select a supported uncompressed mode and capture several individual photos
   while the first is still encoding. Confirm the shutter remains available
   when the camera has fresh eligible frames, each new capture appears as
   Captured locally, and one save pipeline advances them in order.
2. Confirm preview mirroring, camera/mode changes and later frames do not alter
   accepted captures' samples or shutter-time metadata.
3. Quit with waiting captures, then relaunch. Confirm waiting captures resume
   and an interrupted Photos import still requires explicit duplicate
   confirmation. Quitting may finish the active save; it need not finish the
   entire backlog.
4. Fill staging to its capacity limit. Confirm a refused shutter does not add
   a capture row or an orphan UUID folder. Confirm successful saves or explicit
   retained-capture deletion reclaim capacity.

These are manual checks. Synthetic queue tests use temporary staging and an
injected importer; they do not establish live-camera or Photos acceptance.
