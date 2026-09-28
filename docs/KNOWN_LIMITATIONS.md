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

## Automated tests

- 35 tests pass (`PixelBoothTestRunner`): selection/timing, image fidelity
  (random + edge-value fixtures, supported depths/layouts, odd dims, padded
  strides, packed/bi-planar adapters, high-bit-depth packing, alpha, full and
  limited range with superblack/superwhite — exact native-sample comparison
  after AVIF decode), JPEG preservation (segments, scan payload, unknown
  segments, MakerNotes verbatim, malformed rejection), metadata/preview
  isolation, and persistence policy.
- Hardware-dependent checks are reported "Not run", never counted as passed.

## Not verified in this environment (explicitly "Not run")

- **Photos import round-trip**: requires the TCC prompt to be answered by the
  user at run time; the pipeline preserves recoverable data and exposes the
  uncertainty honestly (stage remains `addingToPhotos` until confirmed).
- **Interactive/assistive UI checks** (mirror preview persistence, VoiceOver,
  countdown): the SwiftUI interface builds and the app launches as a process
  (verified), but interactive verification needs a human at the machine.
- **H.264 input**: no H.264 mode was exposed by the available cameras; the
  VideoToolbox decode path is implemented and pipeline-tested but not
  exercised end-to-end with an encoded camera stream.

## Toolchain notes

- Command Line Tools' SwiftPM cannot load the SDK's Testing macro plugin and
  the XCTest toolchain requires agreeing to the Xcode license; the automated
  suite runs through the self-contained runner (`PixelBoothTestRunner`).
  Porting to XCTest is mechanical once a licensed Xcode is available.
- No hand-authored `.xcodeproj`: the Swift package is the buildable unit
  (Xcode opens it with implicit shared schemes). A hand-written pbxproj cannot
  be validated here and would risk committing a broken project; fresh-checkout
  builds go through `scripts/build.sh`.

## Explicitly out of scope (settled)

HEIC output, mixed-codec HEIF, embedded H.264 tracks, video recording, burst
mode, filters, beautification, editing, Photos-library browser, analytics,
accounts, telemetry, app-controlled uploads.
