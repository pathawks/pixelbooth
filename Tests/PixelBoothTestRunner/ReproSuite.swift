import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothAVIF
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata

private enum ReproError: Error {
  case setup(String)
  case assertion(String)
}

private func makeNV12(width: Int, height: Int, fullRange: Bool) throws -> CVPixelBuffer {
  var output: CVPixelBuffer?
  let format =
    fullRange
    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &output)
  guard status == kCVReturnSuccess, let pb = output else {
    throw ReproError.setup("CVPixelBufferCreate: \(status)")
  }
  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }
  guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
    let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
  else {
    throw ReproError.setup("missing NV12 planes")
  }
  let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
  let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
  print(
    "  [repro] width=\(CVPixelBufferGetWidth(pb)) height=\(CVPixelBufferGetHeight(pb)) yStride=\(yStride) uvStride=\(uvStride) format=\(fullRange ? "420f" : "420v")"
  )
  for row in 0..<height {
    for col in 0..<width {
      y.advanced(by: row * yStride).storeBytes(
        of: UInt8((row * 31 + col * 7) & 0xff), toByteOffset: col, as: UInt8.self)
    }
  }
  for row in 0..<(height / 2) {
    for x in 0..<(width / 2) {
      uv.advanced(by: row * uvStride).storeBytes(
        of: UInt8((row * 13 + x * 3) & 0xff), toByteOffset: 2 * x, as: UInt8.self)
      uv.advanced(by: row * uvStride).storeBytes(
        of: UInt8((row * 17 + x * 5) & 0xff), toByteOffset: 2 * x + 1, as: UInt8.self)
    }
  }
  CVBufferSetAttachment(
    pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
  CVBufferSetAttachment(
    pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
    .shouldPropagate)
  CVBufferSetAttachment(
    pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
  CVBufferSetAttachment(
    pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate
  )
  CVBufferSetAttachment(
    pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left,
    .shouldPropagate)
  return pb
}

private func makeCapture(_ pb: CVPixelBuffer, width: Int, height: Int) throws -> CapturedCapture {
  var description: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb,
      formatDescriptionOut: &description) == noErr, let description
  else { throw ReproError.setup("format description") }
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb,
      formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
    let sample
  else { throw ReproError.setup("sample buffer") }
  let frame = DeliveredFrame(
    sampleBuffer: sample, generation: 1, deviceUniqueID: "fixture",
    fourCC: CVPixelBufferGetPixelFormatType(pb), width: CVPixelBufferGetWidth(pb),
    height: CVPixelBufferGetHeight(pb),
    timestampNanos: 1, hostMonotonicNanos: 1, hostWallClockISO: "2026-09-22T12:00:00Z")
  let metadata = FrameMetadataSnapshot(
    mediaTimeNanos: 1, wallClockAnchorISO: "2026-09-22T12:00:00Z", generation: 1)
  return try CapturedCapture(from: frame, metadata: metadata)
}

func runReproSuite() async {
  suite("Repro1552")
  await test("paddedStride1552RoundTrip") {
    let width = 1552
    let height = 1552
    let pb = try makeNV12(width: width, height: height, fullRange: false)
    let capture = try makeCapture(pb, width: width, height: height)
    guard case .planes(let snapshot) = capture.payload else {
      throw ReproError.assertion("expected planes")
    }
    print(
      "  [repro] snapshot.bytesPerRow=\(snapshot.bytesPerRow) rows=\(snapshot.rows) chroma=\(snapshot.chromaWidth)x\(snapshot.chromaHeight)"
    )
    try snapshot.validate(width: capture.width, height: capture.height)
    // Verify Y plane compacted without shear.
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else {
      throw ReproError.assertion("no Y base")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var yBad = 0
    for row in 0..<height {
      for col in 0..<width {
        let exp = y.advanced(by: row * yStride + col).load(as: UInt8.self)
        if snapshot.contiguous[0][row * width + col] != exp { yBad += 1 }
      }
    }
    if yBad > 0 { recordFailure("Y shear: \(yBad) mismatches") }
    // Encode + decode and compare.
    let encoded = try capture.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: encoded.data)
    let yOK = decoded.planes[0] == snapshot.contiguous[0]
    if !yOK { recordFailure("decoded Y plane differs from snapshot") }
    print(
      "  [repro] yBad=\(yBad) decodedYMatches=\(yOK) decodedPlanes=\(decoded.planes.count) decodedWH=\(decoded.width)x\(decoded.height)"
    )
  }
}
