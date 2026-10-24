# Known limitations (honest)

## Estimated AVIF disparity

The build-selected DepthAnythingV2 model estimates relative inverse depth from
a separate full-field RGB rendering (518×392 for Apple's Small models).
Geometry may be stretched for the model;
the primary archival samples remain unchanged. Float predictions are
quantized to gray8 before verified lossless AV1 storage. `NativeFormat=fdis`
describes disparity semantics; `StoredFormat=L008` describes prepared samples.
This is not calibrated camera depth or an exact floating-point archive.
With an application Portrait intent, native Float32 readback uses the fixed
`portrait-relative-v1` virtual range, approximately 1.777344 through 6.09375,
while separate provenance retains the actual raw model minimum and maximum.
The prepared gray8 samples remain unchanged. This render normalization removes
arbitrary model gain and offset from the declared rendering range; it does
not turn the estimate into measured inverse-meters or camera calibration.
Without a Portrait intent, native readback retains the raw model range.

Disparity container associations and native-channel preservation are checked
automatically. A generated fixture verifies ImageIO/AVDepthData Float32 `fdis`
readback, relative accuracy, absent calibration, and every reconstructed sample
against the stored map's documented scaling. This does not measure depth
accuracy on photographs. Apple Photos Portrait recognition for the app's
production metadata profile remains unverified; no Photos library is accessed
by the automated tests. A missing/invalid model
or failed inference fails the requested encoding recoverably rather than
silently omitting depth.

Enabled AVIF outputs include primary MWG `Focus` XMP (centered 10% × 10%
region in saved-image coordinates) and disparity-item
`depthBlurEffect:SimulatedAperture=2.8`. These are explicit application defaults,
not subject detection, camera autofocus observations or physical lens data.
Core Image's public depth-blur factory consumes both fields. That result is
separate from Photos recognizing or exposing its Portrait editing controls.
The earlier locally accepted Portrait fixture also contained an opaque iPhone
`REND` recipe and a generated Apple MakerNote flag; individual necessity was
not isolated. Neither is copied here. No filtering, quality, calibration or
person/pet-detection declarations are fabricated to imitate that file.
Source Focus regions take precedence over the application default. Existing
face regions can gain the default Focus only when their declared image
dimensions match. Unsupported/ambiguous region structures or incompatible
dimensions retain the source Regions unchanged, so the requested default
focus is omitted in those cases.

Validation on October 21, 2026, macOS 27.0.1 (26A434), arm64:
`scripts/validate.sh` passed strict lint, debug app/test builds and all 153
automated tests, including actual pinned-model inference and native `fdis`
reconstruction. Seven hardware/Photos integration checks were not run; they
are printed separately by the runner and are not included in its automated
test totals.

Build-selection validation on October 22, 2026, on the same OS/architecture:
all 158 automated Swift tests passed separately with Small F16, Small F32,
and the personal Large override. Each run included actual model inference,
exact prepared-map storage, and native `fdis` reconstruction. The 17 offline
model-selection/cache tests also passed on Python 3.9.6 and 3.15. This validates
integration and representation, not comparative depth-estimation quality.

Portrait-metadata validation on October 22, 2026, on the same OS/architecture:
`scripts/validate.sh` passed strict lint, debug app/test builds, 17 offline
model-selection/cache checks and all 172 Swift tests with the personal Large
override. The native factory read the default f/2.8 centered focus and a
separate f/5.6 off-center intent with the expected top-left/lower-left
coordinate conversion. Source-region, namespace, RDF-subject and metadata
preservation regressions passed. `scripts/build_app.sh` rebuilt the release
app using that same Large selection. Seven hardware/Photos checks remain not
run; no automated Photos acceptance is claimed.

Rendering-scale validation on October 22, 2026: `scripts/validate.sh` passed
strict lint, debug app/test builds, all 17 model-configuration checks and all
176 Swift tests with the local Large override. The same test runner passed
all 176 tests separately with the checked-in Small F16 and Small F32 models,
including actual inference and every reconstructed native `fdis` sample.
New regressions cover arbitrary model gain/offset, constant maps, separate
raw/render provenance and older journal descriptors without a scale field.
`scripts/build_app.sh` rebuilt the release app with the local Large selection;
strict signature verification passed, with arm64 and minimum macOS 27.0.
The seven hardware/Photos checks remain not run. This implements the chosen
relative normalization; the experimental Photos compatibility bundle is not
included in production output.

The user subsequently reported no Portrait controls for `capture.avif`, SHA-256
`028800835000ab09d3dd8f1d22c575d893ca64036d5e6c27be4a075021429463`.
The unchanged external `mac_diag/inspect_apple_depth.swift` probe accepts its
1552×1552 primary and 518×518 `fdis` auxiliary and obtains a lazy Core Image
filter output. Its application-default focus/aperture XMP is present and read
correctly. Extended read-only render checks, however, return the exact input
image for aperture 1, 2.8 and 16 and a moved focus region; the synthetic fixture
has the same passthrough behavior. The historically accepted control changes
pixels through the same render pipeline. Depth dictionary acceptance, filter
creation and metadata readback therefore do not establish an active blur
effect. Removing only `depthBlurEffect:RenderingParameters` from the control's
in-memory auxiliary metadata makes its filter return the exact input image.
Clearing its separate calibration input preserves the baseline rendered output
(calibration tags remain in its XMP). This establishes a recipe requirement
for native rendering of that tested control, not Photos eligibility rules or
a valid independently generated recipe. The role of the control's Apple
feature flag and other declarations in Photos remains unresolved. Photos was
not opened or modified during these diagnostics.

Local metadata-only compatibility candidates were then generated from that
same capture under the ignored `build/portrait-compatibility/` directory:
REND only, generated feature flag only, and both. The recipe is the explicitly
provenance-labeled opaque iPhone-derived control recipe, not an independently
generated or capture-calibrated production recipe. No calibration, depth
version, quality or filtering declarations were copied. Independent decoding
verified all 3,613,056 primary samples and 268,324 native disparity samples
unchanged in each candidate, along with the source Exif tags and color/
container properties. REND alone activates native rendering and aperture
response on this capture; the feature flag alone does not. One tested moved
focus rectangle produced no additional render change. The combined candidate
SHA-256 is `17fd7df541c0b60278c092bfc865aa8b3d688559d20e24025376a8740d27957d`;
the user reported that it still has no Portrait controls. The user also
confirmed that the existing `portrait-spatial.avif` control, SHA-256
`a3a829abe909d57bd936e95ac5e9a9aa030735efc22d11be06178bc3979ce4e6`, does
have Portrait editing in the current Photos installation.

Further local candidates reproduce the complete control declarations and XML
layout (04), then also its synthetic calibration (05). Candidate 05 has all
23 Apple depth fields in the same order and representation as that control,
with the capture's actual disparity endpoints substituted. All primary and
native disparity samples and original Exif values remain unchanged. Candidate
05 responds to aperture and focus changes in native rendering. The user
confirmed Portrait editing in Photos, but rejected its rendered appearance
because of excessive blur and smearing. Its SHA-256 is
`cba12c79fac73ded99716a7b2046178896f925f0bd26a1b110f62af3d5914f1d`.
The user-supplied rendered PNG has SHA-256
`bbdd3eda2b70d2a0dd120ba84a16ef426fb1c8a607bb50f892084ee8cc12978d`.
The copied high-quality/filtered declarations do not establish model quality
or newly performed filtering, and its calibration is borrowed synthetic data,
not measured camera calibration. Its model disparity scale and borrowed optics
are not physically matched. Available controls and unchanged archival samples
therefore do not establish acceptable Portrait rendering. These local
experiments do not change the app's production output or establish production
acceptance.

Three further local candidates (07–09) change only the declared native render
range to virtual spans of approximately 4.316, 2 and 1, while retaining f/2.8
and the same full-frame focus. All 3,613,056 primary samples, 268,324 stored
gray8 disparity samples, primary/depth AV1 payloads and 20 source Exif tags
remain exact in each file. Public native readback matches the new affine
reconstruction within one Float32 ULP per sample (the established bound is
four ULP); native disparity values intentionally differ from the source.
The actual files produce the expected native factory renders, and candidate
08 responds to aperture and moved-focus changes. These virtual scales are
render choices, not metric estimates or measured optical calibration. The
borrowed diagnostic declarations, synthetic calibration and recipe remain.
The user preferred candidate 07 for this capture and reported that it feels
about right. Portrait-control availability is inferred from the Photos
comparison context rather than separately confirmed. Candidates 08/09 remain
pending, and this single-capture preference does not establish general image
quality or production acceptance. The app now implements that virtual range
for a Portrait intent; the diagnostic copied declarations, calibration and
recipe remain outside its production output.

## Verified on hardware in this environment

- **Real camera enumeration and capture** (macOS 27.0, Build 26A428, M1 Max):
  actual devices enumerated (built-in FaceTime HD Camera + UVC "USB3 Video",
  UltraSemi, VendorID_13407 ProductID_8496); largest-area mode selected
  deterministically (1920×1080, `yuvs`/UYVY advertised, 60 fps max).
- **Delivered vs negotiated fidelity**: the camera advertises UYVY (`yuvs`)
  but macOS actually delivered NV12 (`420v`) — classified truthfully as
  `macDeliveredConverted`, never `nativePreserved`. See
  `docs/TN3121_VERIFICATION.md` for the raw probe log.
- **Mode selection not honored on macOS 27.0 Build 26A428** (built-in
  FaceTime HD Camera): the session delivers only the camera's default
  1920×1080 `420v` stream regardless of `device.activeFormat` or session
  preset; `.inputPriority` is unavailable on macOS. Mode-selection control
  is therefore unestablishable on this OS build and delivered buffers are
  classified honestly as macOS-delivered. See `docs/TN3121_VERIFICATION.md`
  (verified finding 3). The app now prefers the CoreMediaIO HAL backend
  (verified finding 4), which selects the device's advertised stream format
  directly; AVFoundation remains as a fallback when the CMIO path is
  unestablishable for a device or mode.
- **Lossless AVIF archival** from the delivered NV12 planes: encoded in-process
  with pinned libavif 1.3.0 + libaom 3.13.1 (quality 100, speed 0), decoded
  back, and compared in native channels exactly (Y/U/V planes, not RGB
  renderings) before validation success.
- **Durable journal**: crash-recoverable, versioned, with capture UUID,
  whole-file SHA-256 stored in the journal (never self-referentially inside
  the file), and explicit stage states.
- **Advertised-interval enforcement**: the real camera rejects in-between
  frame rates (60/50/30/20/10 fps only); the service snaps to the highest
  advertised rate and records requested vs measured separately.

## Automated tests and implementation acceptance

- **93 tests pass, 0 fail** (`PixelBoothTestRunner`, October 12, 2026,
  macOS 27.0.1 build 26A434): selection/timing, image fidelity
  (random + edge-value fixtures, supported depths/layouts, odd dims, padded
  strides, packed/bi-planar adapters, high-bit-depth packing, alpha, full and
  limited range with superblack/superwhite — exact native-sample comparison
  after AVIF decode), JPEG preservation (segments, scan payload, unknown
  segments, MakerNotes verbatim, malformed rejection), metadata/preview
  isolation, persistence policy, and host-monotonic frame freshness (a stopped
  stream goes stale; invalidation drops retained frames; resumed delivery
  within the shutter timeout is accepted; frames outside the explicitly active
  device/generation are rejected before storage; selection follows the newest
  eligible presentation timestamp within that configuration). Mode identity is
  device-qualified: two cameras exposing the same descriptive mode label are
  distinct modes, so a camera switch can never be mistaken for a mode that is
  already selected.
- Hardware-dependent checks are reported "Not run", never counted as passed.
  Device-disconnect behavior (unplug mid-stream) is in that set; the
  store-level age/invalidation path is covered by the Freshness suite.

## Not verified in this environment (explicitly "Not run")

- **Photos import round-trip**: requires the TCC prompt to be answered by the
  user at run time; the pipeline preserves recoverable data and exposes the
  uncertainty honestly (stage remains `addingToPhotos` until confirmed).
- **Interactive/assistive UI checks** (minimum-size layout, mirror preview,
  VoiceOver, keyboard focus, countdown, light/dark and reduced motion): the
  updated SwiftUI interface builds, but live visual/accessibility verification
  was unavailable because Accessibility and Screen Recording access was not
  enabled. Source changes are not presented as runtime UI evidence.
- **Live camera switching between two connected cameras**: the selection path
  is source-verified (a camera change always reconfigures for the new device,
  independent of the mode-selection observer, and an unconfigurable selection
  tears the previous stream down) and mode identity is device-qualified and
  unit-tested; no live switch was performed in this environment.
- **Live H.264 input and wider source representations**: the synthetic 8-bit
  encoded-fixture-to-AVIF test passed on macOS 27.0.1 on October 12, 2026.
  This supersedes the older decoder-session failure (`-12911`) for that
  fixture only. No live H.264 camera was tested in this review. The decoder
  requests 8-bit, limited-range 4:2:0 output; preservation of other source
  representations is unverified and needs an explicit fidelity gate.
- **BGR24 live delivery**: the production packed-RGB adapter, snapshot, and
  exact AVIF round trip pass with a padded-stride fixture. CoreVideo refused a
  synthetic 24BG buffer in the local test setup (`-6680`), and no physical
  camera was used to verify that format arriving as a `CVPixelBuffer`.
- **Additional packed/high-depth layouts**: `v210` is packed 10-bit 4:2:2 and
  has no current archival adapter; `x422`, `xf22`, `x444`, `xf44`, and `y420`
  are classified but not routed to archival adapters. See the capability matrix.

## Toolchain notes

- Command Line Tools' SwiftPM cannot load the SDK's Testing macro plugin and
  the XCTest toolchain requires agreeing to the Xcode license; the automated
  suite runs through the self-contained runner (`PixelBoothTestRunner`).
  Porting to XCTest is mechanical once a licensed Xcode is available.
- No hand-authored `.xcodeproj`: the Swift package is the buildable unit
  (Xcode opens it with implicit shared schemes). A hand-written pbxproj cannot
  be validated here and would risk committing a broken project; fresh-checkout
  validation goes through `scripts/validate.sh`, while `.app` assembly is a
  separate step through `scripts/build_app.sh`.

## Explicitly out of scope (settled)

HEIC output, mixed-codec HEIF, embedded H.264 tracks, video recording, burst
mode, filters, beautification, editing, Photos-library browser, analytics,
accounts, telemetry, app-controlled uploads.

## Remaining implementation findings

Interlaced samples, JPEG metadata/completeness, and MJPEG acquisition-policy
handling have known gaps. Camera-switching, preview, queue-bounding and staging-
capacity issues also require further work. The Photos entitlement, capture
dismissal controls, 10-bit range propagation, completed-history capacity check
and app notice packaging have been corrected. Live Photos authorization/import
and interactive UI acceptance remain manual.
