import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothAVIF
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata

private enum StreamColorTestError: Error { case fixture }

private func streamColorFrame(
  matrix: String? = nil, generation: Int = 1, device: String = "synthetic-camera",
  width: Int = 8, height: Int = 4, fourCC: UInt32 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  mediaTime: UInt64 = 123
) throws -> DeliveredFrame {
  var buffer: CVPixelBuffer?
  guard CVPixelBufferCreate(nil, width, height, fourCC, nil, &buffer) == kCVReturnSuccess,
    let buffer, let space = CGColorSpace(name: CGColorSpace.sRGB)
  else { throw StreamColorTestError.fixture }
  CVPixelBufferLockBaseAddress(buffer, [])
  for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
      CVPixelBufferUnlockBaseAddress(buffer, [])
      throw StreamColorTestError.fixture
    }
    base.initializeMemory(
      as: UInt8.self, repeating: 128,
      count: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        * CVPixelBufferGetHeightOfPlane(buffer, plane))
  }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  if let matrix {
    CVBufferSetAttachment(
      buffer, kCVImageBufferYCbCrMatrixKey, matrix as CFString, .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C,
      .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate)
  }
  CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
  var format: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
    let format
  else { throw StreamColorTestError.fixture }
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: buffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
  else { throw StreamColorTestError.fixture }
  return DeliveredFrame(
    sampleBuffer: sample, generation: generation, deviceUniqueID: device,
    fourCC: fourCC, width: width, height: height, timestampNanos: mediaTime,
    hostMonotonicNanos: 456, hostWallClockISO: "2026-10-24T01:02:03.004Z")
}

func runStreamColorObservationSuite() async {
  suite("StreamColorObservations")

  await test("firstExplicitTagsAndLaterOmissionRemainSeparateEvidence") {
    var tracker = StreamColorObservationTracker()
    let first = try streamColorFrame(matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    let one = tracker.observe(first)
    check(one.count == 1 && one[0].frameIndex == 1, "first delivered frame is retained")
    check(
      one[0].pixelBuffer.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String,
      "actual delivered matrix is recorded")
    check(
      one[0].formatDescription.matrix == one[0].pixelBuffer.matrix,
      "format and pixel tags are kept in separate scopes")
    var missing = try streamColorFrame(mediaTime: 999)
    let two = tracker.observe(missing)
    check(two.count == 2 && two[1].frameIndex == 2, "metadata omission is a distinct observation")
    check(two[1].pixelBuffer.matrix == nil, "absence never inherits earlier tags")
    check(
      two[1].pixelBuffer.colorSpaceICCProfileSHA256
        == two[0].pixelBuffer.colorSpaceICCProfileSHA256
        && two[1].pixelBuffer.colorSpaceICCProfileSHA256?.count == 64,
      "identical ICC hashes do not fill missing matrix values")
    check(
      two[1].mediaTimeNanos == 999 && two[1].hostMonotonicNanos == 456
        && two[1].observedAtISO == missing.hostWallClockISO,
      "media and host observations remain distinct and timestamped")
    missing.streamColorObservations = two
    let metadata = FrameMetadataSnapshot(
      mediaTimeNanos: 999, wallClockAnchorISO: missing.hostWallClockISO, generation: 1)
    let capture = try CapturedCapture(from: missing, metadata: metadata)
    check(capture.metadata.streamColorObservations == two, "shutter copies the selected history")
    check(capture.color?.matrix == nil, "stream history is never a per-frame color fallback")
    let restored = try JSONDecoder().decode(
      CapturedCapture.self, from: JSONEncoder().encode(capture))
    check(restored.metadata.streamColorObservations == two, "history survives durable JSON")
    let result = try restored.encodeAVIF()
    check(
      try LosslessAVIF.decode(encoded: result.data).matrixCoefficients == 2,
      "known first-frame matrix never replaces unspecified matrix in later AVIF")
    check(tracker.observe(missing).count == 2, "repeated omission does not grow history")
  }

  await test("streamIdentityChangesResetHistoryAndFrameIndex") {
    let changes: [(Int, String, Int, Int, UInt32)] = [
      (2, "synthetic-camera", 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (1, "another-camera", 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (1, "synthetic-camera", 10, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (1, "synthetic-camera", 8, 6, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (1, "synthetic-camera", 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    ]
    for (generation, device, width, height, fourCC) in changes {
      var tracker = StreamColorObservationTracker()
      _ = tracker.observe(try streamColorFrame(matrix: "first-explicit-matrix"))
      let observations = tracker.observe(
        try streamColorFrame(
          generation: generation, device: device, width: width, height: height, fourCC: fourCC))
      check(
        observations.count == 1 && observations[0].frameIndex == 1
          && observations[0].pixelBuffer.matrix == nil,
        "device, generation, dimensions and representation changes cannot inherit prior evidence")
    }
  }

  await test("distinctHistoryIsBoundedAndPreservesFirstAndRecentVariants") {
    var tracker = StreamColorObservationTracker()
    var history: [DeliveredColorObservation] = []
    for index in 0..<32 {
      history = tracker.observe(try streamColorFrame(matrix: "synthetic-matrix-\(index)"))
      check(
        history.count <= StreamColorObservationTracker.maximumObservations,
        "delivery history remains bounded")
    }
    check(history.count == 8, "at most eight metadata variants are retained")
    check(history.first?.frameIndex == 1, "first actual metadata survives churn")
    check(history.last?.frameIndex == 32, "most recent distinct metadata survives churn")
    check(
      history.last?.pixelBuffer.matrix == "synthetic-matrix-31", "latest variant is not discarded")
  }
}
