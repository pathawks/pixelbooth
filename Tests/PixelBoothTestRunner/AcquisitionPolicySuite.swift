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

  await test("selectedJPEGModeRejectsDecodedPixelSubstitutes") {
    let selected = CaptureFormat(width: 16, height: 16, fourCC: PixelFormatFourCC.mjpeg)
    for deliveredFourCC in [PixelFormatFourCC.fourTwentyV, PixelFormatFourCC.bgra] {
      do {
        _ = try AcquisitionPolicy.evaluate(
          deviceUniqueID: "cam", generation: 1,
          expectedDeviceID: "cam", expectedGeneration: 1,
          selected: selected,
          delivered: CaptureFormat(width: 16, height: 16, fourCC: deliveredFourCC))
        throw AcquisitionPolicyFailure.assertion(
          "selected JPEG mode accepted decoded \(CaptureFormat.fourCCString(deliveredFourCC))")
      } catch let error as CaptureFidelityError {
        guard case .jpegCodingDataUnavailable = error else {
          throw AcquisitionPolicyFailure.assertion(
            "decoded substitute failed for the wrong reason: \(error)")
        }
      }
    }
  }

  await test("JPEGFourCCSpellingsRemainEquivalentWithHonestProvenance") {
    let jpegTypes = [PixelFormatFourCC.mjpeg, PixelFormatFourCC.jpeg, PixelFormatFourCC.dmb1]
    for selectedFourCC in jpegTypes {
      for deliveredFourCC in jpegTypes {
        let evidence = try AcquisitionPolicy.evaluate(
          deviceUniqueID: "cam", generation: 1,
          expectedDeviceID: "cam", expectedGeneration: 1,
          selected: CaptureFormat(width: 16, height: 16, fourCC: selectedFourCC),
          delivered: CaptureFormat(width: 16, height: 16, fourCC: deliveredFourCC))
        guard evidence.fidelity == .macDeliveredUnknownUpstream,
          evidence.knownConversions.isEmpty
        else {
          throw AcquisitionPolicyFailure.assertion(
            "JPEG aliases must preserve coding data without claiming upstream proof")
        }
      }
    }
    let established = try AcquisitionPolicy.evaluate(
      deviceUniqueID: "cam", generation: 1,
      expectedDeviceID: "cam", expectedGeneration: 1,
      selected: CaptureFormat(width: 16, height: 16, fourCC: PixelFormatFourCC.mjpeg),
      delivered: CaptureFormat(width: 16, height: 16, fourCC: PixelFormatFourCC.jpeg),
      upstreamNoConversionEstablished: true)
    guard established.fidelity == .nativePreserved else {
      throw AcquisitionPolicyFailure.assertion("verified JPEG alias should remain native")
    }
  }

  await test("unknownJPEGUpstreamProvenanceDoesNotBlockMatchingCodingData") {
    let matching = CaptureFormat(width: 16, height: 16, fourCC: PixelFormatFourCC.mjpeg)
    let evidence = try AcquisitionPolicy.evaluate(
      deviceUniqueID: "cam", generation: 1,
      expectedDeviceID: "cam", expectedGeneration: 1,
      selected: matching, delivered: matching)
    guard evidence.fidelity == .macDeliveredUnknownUpstream,
      evidence.knownConversions.isEmpty
    else {
      throw AcquisitionPolicyFailure.assertion(
        "uncertain upstream provenance must not gate supported JPEG passthrough")
    }
  }
}
