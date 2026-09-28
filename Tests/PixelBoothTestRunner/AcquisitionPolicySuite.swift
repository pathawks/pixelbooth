import Foundation
import PixelBoothCore

private enum AcquisitionPolicyFailure: Error { case assertion(String) }

func runAcquisitionPolicySuite() async {
  suite("AcquisitionPolicy")
  await test("verifiedFourCCFactsAndUnknownUpstreamProvenance") {
    let yuvs = CaptureFormatFacts.applying(
      to: CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.yuvs))
    let v210 = CaptureFormatFacts.applying(
      to: CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.v210))
    guard yuvs.bitsPerChannel == 8, yuvs.chromaSampling == .yuv422,
      v210.bitsPerChannel == 10, v210.chromaSampling == .yuv422
    else {
      throw AcquisitionPolicyFailure.assertion("SDK FourCC mapping mismatch")
    }
    let unknown = CaptureFormat(width: 8, height: 4, fourCC: fourCC("qxyz"))
    let evidence = try AcquisitionPolicy.evaluate(
      deviceUniqueID: "cam", generation: 3,
      expectedDeviceID: "cam", expectedGeneration: 3, selected: unknown, delivered: unknown)
    guard evidence.fidelity == .macDeliveredUnknownUpstream
    else {
      throw AcquisitionPolicyFailure.assertion(
        "unknown upstream provenance was not preserved in the evidence")
    }
  }
  await test("knownPrecisionRangeColorModelAndChromaChangesReject") {
    let base = CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.fourTwentyV)
    func expectRejected(_ selected: CaptureFormat, _ delivered: CaptureFormat) throws {
      do {
        _ = try AcquisitionPolicy.evaluate(
          deviceUniqueID: "cam", generation: 1,
          expectedDeviceID: "cam", expectedGeneration: 1, selected: selected, delivered: delivered)
        throw AcquisitionPolicyFailure.assertion("prohibited format change was accepted")
      } catch is AcquisitionPolicyFailure {
        throw AcquisitionPolicyFailure.assertion("prohibited format change was accepted")
      } catch {
        // Expected fail-closed policy rejection.
      }
    }
    try expectRejected(CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.x420), base)
    try expectRejected(
      base, CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.fourTwentyF))
    try expectRejected(CaptureFormat(width: 8, height: 4, fourCC: PixelFormatFourCC.bgra), base)
    let left = CaptureFormat(
      width: 8, height: 4, fourCC: PixelFormatFourCC.nv12, chromaLocation: .left)
    let top = CaptureFormat(
      width: 8, height: 4, fourCC: PixelFormatFourCC.nv12, chromaLocation: .topLeft)
    try expectRejected(left, top)
  }
}
