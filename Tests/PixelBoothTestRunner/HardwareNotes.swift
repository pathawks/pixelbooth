// Hardware/permission-dependent integration checks.
// These are enumerated and reported as "Not run" when the environment lacks
// the hardware or authorization. They are never counted as passed.

import Foundation

func runHardwareDependentNotes() {
  suite("HardwareDependent")
  func notRun(_ name: String, reason: String) {
    print("NOT RUN HardwareDependent.\(name): \(reason)")
  }

  print("--- Hardware/permission-dependent integration checks (require hardware) ---")
  notRun(
    "realCameraEnumeration",
    reason: "requires a physical camera and camera permission (TCC)")
  notRun(
    "nativeDeliveryVerification",
    reason:
      "requires a UVC camera; verify empty-dictionary videoSettings native delivery per TN3121 against installed SDK"
  )
  notRun(
    "h264PresentationOrderSelection",
    reason: "requires an H.264-capable camera; select by presentation time")
  notRun(
    "photosImportAndOriginalHashComparison",
    reason:
      "requires Photos add-only authorization; opt-in resource retrieval needs read authorization")
  notRun(
    "systemPhotoLibraryRegression",
    reason:
      "requires PhotoKit authorization; ordinary AVIF output must be preserved, never substituted")
  notRun(
    "crashRecoveryOnHardware",
    reason: "crash/relaunch at each save stage requires app relaunch on hardware")
  notRun(
    "disconnectInvalidatesFreshness",
    reason:
      "requires a physical camera; unplug mid-stream and verify the shutter disables and no frame from the stopped stream is accepted (store-level age/invalidation behavior is covered by the Freshness suite)"
  )
}
