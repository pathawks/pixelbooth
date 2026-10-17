# Known limitations (honest)

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
