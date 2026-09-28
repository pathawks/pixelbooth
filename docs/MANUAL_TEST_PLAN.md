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
4. If upstream behavior cannot be established, verify the app shows the
   compatibility-path label and requires explicit acknowledgment before
   accepting a capture.

Expected: classification matches the actual evidence.

## 3. JPEG passthrough on hardware

1. Capture a photo in MJPEG mode.
2. Compare all image-coding segments and scan payload between the staged
   snapshot and the saved file.
3. Add unknown APP segments and MakerNotes to the camera stream (if exposed)
   and confirm they survive verbatim.

Expected: image-coding data identical; only metadata additions differ.

## 4. Uncompressed capture → lossless AVIF

1. Select an uncompressed mode (NV12/420v/BGRA/v210 if exposed).
2. Capture; confirm the saved file is AVIF, matrix identity for RGB, range
   signaled as stored.
3. Verify the journal shows Encoding → Validating success.

Expected: lossless round-trip verified; no invented settings.

## 5. H.264 input

1. Select an H.264 mode.
2. Confirm warm-up pictures excluded from eligibility do not break decoder
   dependencies.
3. Confirm the picture is selected by presentation time.
4. Confirm the saved file contains no H.264 source stream.

## 6. Photos-first saving

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

## 8. Disconnect / sleep / mode changes

1. Unplug the UVC camera mid-stream: app must not auto-activate another camera.
2. Sleep and wake: session recovers; stale frames excluded.
3. Change mode: configuration generation increments; queued old-mode frames
   rejected.

## 9. Interface checks

1. View > Mirror Preview persists across relaunch; default off.
2. Space captures when no focused control conflicts.
3. Countdown Off/3s/10s; completion is the shutter event.
4. VoiceOver labels on shutter/dropdowns/status; keyboard navigation works.
5. 100% inspection shows uncropped pixels; fit shows the full frame.
