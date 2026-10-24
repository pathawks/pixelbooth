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
5. On a BRIO, check the distinct 1080p representations as well as both 4K
   sizes: rates must belong to the exact format, including distinctions beyond
   dimensions/FourCC. Switch modes and verify that current CMIO supported rates
   refresh the selected label without losing the selection or restarting it
   again. Keep configured and measured delivery rates separate from the maximum.

Expected: real devices, honest mode labels.

USB identity checks: compare the selected camera with its physical USB entry,
including two identical models on different ports. Verify that AVFoundation
manufacturer wins, then a reported USB manufacturer string, then the attributed
VID lookup. Inspect the retained capture/report after unplugging: VID, PID,
USB strings, association method and observation time must remain available.
Do not infer a connection from a matching camera display name.

Metadata report checks: use a known HDR/metadata-capable source. An unmapped
supplemental attachment must not reject the shutter. Verify exact native-channel
output, report availability in Capture Status, exported JSON, archive data in
the finalized file's XMP, and survival across relaunch without duplicate import.
Confirm local report captures consume staging capacity and explicit deletion
reclaims it. If the base color interpretation is unavailable, verify a durable
local source/report and an export limitation rather than a discarded shutter.

For YUV with an ICC profile but no matrix attachment, confirm the image saves
with an unspecified matrix and an available report. Check that early stream
color observations survive capture, relaunch and XMP embedding, retain their
own frame/time/generation/profile identity, and do not become a shutter-frame
matrix override. Reconfigure or disconnect and verify old stream observations
cannot appear in a new configuration. Compare the opt-in color probe across
backends; see [the Brio investigation](BRIO_COLOR_INVESTIGATION.md).

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

### Estimated disparity

For build-selection regression, use explicit `PIXELBOOTH_DEPTH_VARIANT=SmallF16`
or `SmallF32` when assembling the app. A personal `depth-model.local.json`
override applies only when no explicit preset is selected. Confirm the bundled
`DepthModel.json`, model and license match that selection, then reopen the
assembled app before the capture checks below. A Large build must identify
Large in saved metadata and the inspector rather than retaining Small labels.

1. Build with `scripts/build_app.sh` and reopen the assembled app. In Settings,
   confirm Include Estimated Disparity in AVIF is enabled. Capture a supported
   uncompressed or decoded H.264 frame and confirm the save details identify
   DepthAnythingV2, relative disparity, and verified `fdis/L008` storage.
2. Compare with the setting disabled: primary dimensions, native channels,
   range, color descriptors and alpha must remain identical for the same staged
   source. Mirror Preview must not mirror either saved primary or saved map.
3. Queue a capture, change the setting, and relaunch with waiting work. Its
   shutter-time request must survive; changing Settings affects new captures.
4. Separately inspect auxiliary readback using ImageIO/AVDepthData, recording
   actual type, geometry, sample representation and relative accuracy. Failure
   to expose an Apple depth dictionary is distinct from AVIF container/sample
   verification and must be reported.
5. Check that primary XMP contains an MWG `Focus` region with the saved primary
   dimensions and that depth XMP contains `SimulatedAperture=2.8`, with
   application-default provenance. The initial focus is centered; it is not a
   detected person, pet or camera autofocus result. The native Core Image
   depth-blur factory must read aperture 2.8 and focus rectangle
   `[0.45, 0.45, 0.1, 0.1]` in normalized lower-left coordinates.
6. Only the user performs Photos import/recognition checks. Record the exact
   file SHA-256 and Photos/macOS versions, whether Portrait controls appear,
   and whether toggling Portrait, changing aperture and moving focus visibly
   work after reopening the photo. Record export/reimport separately. These
   behaviors are not established by the automated tests. Do not infer metric
   distances, camera calibration, or Portrait support from `fdis` or native
   Core Image rendering alone.

Automated tests use generated patterns and an injected importer; they do not
open, import into, or otherwise modify a Photos library.

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
