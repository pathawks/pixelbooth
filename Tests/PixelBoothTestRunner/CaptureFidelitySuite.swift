import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata

private enum CaptureFidelityTestError: Error {
  case setup(String)
  case assertion(String)
}
private let fixtureWidth = 60
private let fixtureHeight = 4

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw CaptureFidelityTestError.assertion(message) }
}

private func makeNV12(fullRange: Bool) throws -> CVPixelBuffer {
  var output: CVPixelBuffer?
  let format =
    fullRange
    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, fixtureWidth, fixtureHeight, format,
    nil, &output)
  guard status == kCVReturnSuccess, let pb = output else {
    throw CaptureFidelityTestError.setup("CVPixelBufferCreate: \(status)")
  }
  CVPixelBufferLockBaseAddress(pb, [])
  guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
    let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
  else {
    CVPixelBufferUnlockBaseAddress(pb, [])
    throw CaptureFidelityTestError.setup("missing NV12 planes")
  }
  let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
  let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
  guard yStride > fixtureWidth, uvStride > fixtureWidth else {
    throw CaptureFidelityTestError.setup("fixture did not receive padded CoreVideo strides")
  }
  for row in 0..<fixtureHeight {
    for col in 0..<fixtureWidth {
      y.advanced(by: row * yStride).storeBytes(
        of: UInt8([0, 16, 17, 235, 236, 255][(row + col) % 6]), toByteOffset: col, as: UInt8.self)
    }
  }
  for row in 0..<2 {
    for col in 0..<fixtureWidth {
      uv.advanced(by: row * uvStride).storeBytes(
        of: UInt8((row * 71 + col * 43) & 0xff), toByteOffset: col, as: UInt8.self)
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, [])
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

private func makeCapture(
  _ pb: CVPixelBuffer, reportedWidth: Int? = nil, reportedHeight: Int? = nil
) throws -> CapturedCapture {
  var description: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb,
      formatDescriptionOut: &description) == noErr, let description
  else { throw CaptureFidelityTestError.setup("format description") }
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pb,
      formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
    let sample
  else { throw CaptureFidelityTestError.setup("sample buffer") }
  let frame = DeliveredFrame(
    sampleBuffer: sample, generation: 1, deviceUniqueID: "fixture",
    fourCC: CVPixelBufferGetPixelFormatType(pb),
    width: reportedWidth ?? CVPixelBufferGetWidth(pb),
    height: reportedHeight ?? CVPixelBufferGetHeight(pb),
    timestampNanos: 1, hostMonotonicNanos: 1, hostWallClockISO: "2026-09-22T12:00:00Z")
  let metadata = FrameMetadataSnapshot(
    mediaTimeNanos: 1, wallClockAnchorISO: "2026-09-22T12:00:00Z", generation: 1)
  return try CapturedCapture(from: frame, metadata: metadata)
}

private func makeBGRA() throws -> CVPixelBuffer {
  var output: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, 5, 3, kCVPixelFormatType_32BGRA, nil, &output)
  guard status == kCVReturnSuccess, let pb = output else {
    throw CaptureFidelityTestError.setup("BGRA CVPixelBufferCreate: \(status)")
  }
  CVPixelBufferLockBaseAddress(pb, [])
  guard let base = CVPixelBufferGetBaseAddress(pb) else {
    CVPixelBufferUnlockBaseAddress(pb, [])
    throw CaptureFidelityTestError.setup("BGRA base")
  }
  let stride = CVPixelBufferGetBytesPerRow(pb)
  for row in 0..<3 {
    for col in 0..<5 {
      let p = base.advanced(by: row * stride + col * 4)
      p.storeBytes(of: UInt8(row * 17 + col), toByteOffset: 0, as: UInt8.self)
      p.storeBytes(of: UInt8(220 - row * 13 - col), toByteOffset: 1, as: UInt8.self)
      p.storeBytes(of: UInt8(row * 31 + col * 9), toByteOffset: 2, as: UInt8.self)
      p.storeBytes(of: UInt8(255 - row * 7 - col * 3), toByteOffset: 3, as: UInt8.self)
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, [])
  CVBufferSetAttachment(
    pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
  CVBufferSetAttachment(
    pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
  return pb
}

func runCaptureFidelitySuite() async {
  suite("CaptureSnapshotAndColor")
  await test("paddedNV12JSONProductionEncodePreservesRangeAndSamples") {
    for fullRange in [false, true] {
      let pb = try makeNV12(fullRange: fullRange)
      let capture = try makeCapture(pb)
      let expectedY = (0..<fixtureHeight).flatMap { row in
        (0..<fixtureWidth).map { col in UInt8([0, 16, 17, 235, 236, 255][(row + col) % 6]) }
      }
      let expectedU = (0..<(fixtureHeight / 2)).flatMap { row in
        (0..<(fixtureWidth / 2)).map { x in UInt8((row * 71 + 2 * x * 43) & 0xff) }
      }
      let expectedV = (0..<(fixtureHeight / 2)).flatMap { row in
        (0..<(fixtureWidth / 2)).map { x in UInt8((row * 71 + (2 * x + 1) * 43) & 0xff) }
      }
      CVPixelBufferLockBaseAddress(pb, [])
      for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) {
          memset(
            base, 0,
            CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane)
          )
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, [])
      guard case .planes(let snapshot) = capture.payload else {
        throw CaptureFidelityTestError.assertion("expected planes")
      }
      try require(
        snapshot.bytesPerRow == [fixtureWidth, fixtureWidth / 2, fixtureWidth / 2],
        "snapshot strides compacted")
      try require(
        snapshot.rows == [fixtureHeight, fixtureHeight / 2, fixtureHeight / 2],
        "plane rows preserved")
      let encodedJSON = try JSONEncoder().encode(capture)
      let restored = try JSONDecoder().decode(CapturedCapture.self, from: encodedJSON)
      let result = try restored.encodeAVIF()
      let decoded = try LosslessAVIF.decode(encoded: result.data)
      try require(decoded.range == (fullRange ? 1 : 0), "range descriptor preserved")
      try require(
        decoded.colorPrimaries == 1 && decoded.transferCharacteristics == 1
          && decoded.matrixCoefficients == 1,
        "CICP descriptors preserved")
      try require(
        decoded.chromaSamplePosition == 1, "left chroma location maps to vertical position")
      try require(decoded.planes[0] == expectedY, "all Y rows preserved")
      try require(
        decoded.planes[1] == expectedU && decoded.planes[2] == expectedV,
        "asymmetric UV samples preserved")
    }
  }
  await test("tenBitAdapterSnapshotJSONAndAVIFPreserveMeaningfulDepth") {
    let width = 4
    let height = 4
    let yValues: [UInt16] = [
      0, 1, 255, 1023, 16, 64, 512, 1022, 30, 90, 400, 900, 3, 42, 777, 1000,
    ]
    let uvValues: [UInt16] = [0, 1023, 17, 1000, 255, 768, 511, 512]
    let yStride = width * 2 + 4
    let uvStride = width * 2 + 4
    var yBytes = Data(repeating: 0xA5, count: yStride * height)
    var uvBytes = Data(repeating: 0x5A, count: uvStride * (height / 2))
    for row in 0..<height {
      for column in 0..<width {
        var sample = (yValues[row * width + column] << 6).littleEndian
        withUnsafeBytes(of: &sample) { bytes in
          yBytes.replaceSubrange(
            (row * yStride + column * 2)..<(row * yStride + column * 2 + 2), with: bytes)
        }
      }
    }
    for row in 0..<(height / 2) {
      for column in 0..<width {
        var sample = (uvValues[row * width + column] << 6).littleEndian
        withUnsafeBytes(of: &sample) { bytes in
          uvBytes.replaceSubrange(
            (row * uvStride + column * 2)..<(row * uvStride + column * 2 + 2), with: bytes)
        }
      }
    }
    let adapted = try yBytes.withUnsafeBytes { y in
      try uvBytes.withUnsafeBytes { uv in
        try SampleLayoutAdapter.adaptBiPlanar10BitYUV(
          yPlane: y.baseAddress!, yBytesPerRow: yStride,
          chromaPlane: uv.baseAddress!, chromaBytesPerRow: uvStride,
          width: width, height: height)
      }
    }
    defer { for pointer in adapted.ownedStorage.compactMap({ $0 }) { pointer.deallocate() } }
    let snapshot = try CapturedCapture.snapshotPlanes(from: adapted)
    var capture = try makeCapture(makeNV12(fullRange: false))
    capture.fourCC = PixelFormatFourCC.x420
    capture.width = width
    capture.height = height
    capture.payload = .planes(snapshot)
    capture.color = CapturedCapture.ColorDescriptor(
      yuvRange: .limited, primaries: 1, transfer: 1, matrix: 1,
      chromaLocation: .left, iccProfile: nil)

    let restored = try JSONDecoder().decode(
      CapturedCapture.self, from: JSONEncoder().encode(capture))
    guard case .planes(let restoredSnapshot) = restored.payload else {
      throw CaptureFidelityTestError.assertion("expected serialized 10-bit planes")
    }
    try require(
      restoredSnapshot.bitsPerChannel == 10 && restoredSnapshot.bytesPerSample == 2,
      "JSON retains ten meaningful bits in each 16-bit sample")
    let encoded = try restored.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: encoded.data)
    try require(
      decoded.depth == 10 && decoded.range == 0, "AVIF retains 10-bit limited-range facts")
    try require(
      decoded.planes == restoredSnapshot.contiguous,
      "encoded AVIF decodes to the exact unpacked Y/U/V samples")
    try require(yValues.contains(0) && yValues.contains(1023), "fixture covers ten-bit endpoints")
  }
  await test("malformedSnapshotAndLegacyUnknownRangeRefused") {
    let pb = try makeNV12(fullRange: false)
    let capture = try makeCapture(pb)
    guard case .planes(var malformedSnapshot) = capture.payload else {
      throw CaptureFidelityTestError.assertion("expected planes")
    }
    malformedSnapshot.rows[0] = 1
    var malformedCapture = capture
    malformedCapture.payload = .planes(malformedSnapshot)
    do {
      _ = try malformedCapture.encodeAVIF()
      throw CaptureFidelityTestError.assertion("short Y plane encoded")
    } catch is CapturedCapture.SnapshotError {}
    var legacyCapture = capture
    legacyCapture.metadata.pixelBufferAttachments[
      CapturedCapture.completeColorAttachmentSnapshotKey] = "true"
    var encoded = try JSONEncoder().encode(legacyCapture)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object.removeValue(forKey: "color")  // pre-descriptor serialized capture
    encoded = try JSONSerialization.data(withJSONObject: object)
    let legacy = try JSONDecoder().decode(CapturedCapture.self, from: encoded)
    do {
      _ = try legacy.encodeAVIF()
      throw CaptureFidelityTestError.assertion("legacy unknown range encoded")
    } catch is CaptureFidelityTestError {
      throw CaptureFidelityTestError.assertion("legacy unknown range encoded")
    } catch {}
  }
  await test("archivalGeometryComesFromRetainedImagePlanes") {
    let pb = try makeNV12(fullRange: false)
    let capture = try makeCapture(
      pb, reportedWidth: fixtureWidth + 4, reportedHeight: fixtureHeight + 2)
    try require(
      capture.width == fixtureWidth && capture.height == fixtureHeight,
      "pixel-buffer geometry is authoritative over a stale format description")

    // Older queued captures may already contain stale format-description
    // dimensions. The retained plane layout still identifies the exact image.
    var legacyCapture = capture
    legacyCapture.width += 4
    legacyCapture.height += 2
    let restored = try JSONDecoder().decode(
      CapturedCapture.self, from: JSONEncoder().encode(legacyCapture))
    let encoded = try restored.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: encoded.data)
    try require(
      decoded.width == fixtureWidth && decoded.height == fixtureHeight,
      "legacy stale dimensions do not prevent native-plane encoding")
  }
  await test("legacyColorDescriptorRecoversOnlyFromSavedEvidence") {
    let pb = try makeNV12(fullRange: false)
    var capture = try makeCapture(pb)
    capture.color = nil
    capture.metadata.pixelBufferAttachments = [
      CapturedCapture.completeColorAttachmentSnapshotKey: "true",
      kCVImageBufferColorPrimariesKey as String:
        kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
      kCVImageBufferTransferFunctionKey as String:
        kCVImageBufferTransferFunction_ITU_R_709_2 as String,
      kCVImageBufferYCbCrMatrixKey as String:
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
      kCVImageBufferChromaLocationTopFieldKey as String:
        kCVImageBufferChromaLocation_Left as String,
      kCVImageBufferChromaLocationBottomFieldKey as String:
        kCVImageBufferChromaLocation_Left as String,
    ]
    let delivered = CaptureFormatFacts.applying(
      to: CaptureFormat(
        width: fixtureWidth, height: fixtureHeight,
        fourCC: CVPixelBufferGetPixelFormatType(pb)))
    capture.acquisitionEvidence = AcquisitionEvidence(
      deviceUniqueID: "fixture", generation: 1,
      selectedFormat: delivered, deliveredFormat: delivered,
      fidelity: .macDeliveredUnknownUpstream, knownConversions: [])

    let encoded = try capture.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: encoded.data)
    try require(decoded.range == 0, "limited range was recovered from delivered-format evidence")
    try require(
      decoded.colorPrimaries == 1 && decoded.transferCharacteristics == 1
        && decoded.matrixCoefficients == 1 && decoded.chromaSamplePosition == 1,
      "color attachments were recovered without inventing interpretation")

    var incomplete = capture
    incomplete.metadata.pixelBufferAttachments.removeValue(
      forKey: CapturedCapture.completeColorAttachmentSnapshotKey)
    do {
      _ = try incomplete.encodeAVIF()
      throw CaptureFidelityTestError.assertion("incomplete legacy color attachments were trusted")
    } catch CapturedCapture.SnapshotError.unsupportedColorDescriptor {}
  }
  await test("rgbCICPAndAlphaSurviveProductionFinalization") {
    let bgra = try makeBGRA()
    let capture = try makeCapture(bgra)
    guard case .planes(let initial) = capture.payload else {
      throw CaptureFidelityTestError.assertion("expected initial BGRA planes")
    }
    try initial.validate(width: capture.width, height: capture.height)
    let restored = try JSONDecoder().decode(
      CapturedCapture.self, from: JSONEncoder().encode(capture))
    let encoded = try restored.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: encoded.data)
    guard case .planes(let source) = restored.payload else {
      throw CaptureFidelityTestError.assertion("expected BGRA planes")
    }
    try require(
      decoded.colorPrimaries == 1 && decoded.transferCharacteristics == 13
        && decoded.matrixCoefficients == 0,
      "RGB color description preserved")
    try require(
      decoded.planes[0] == source.contiguous[0] && decoded.planes[1] == source.contiguous[1]
        && decoded.planes[2] == source.contiguous[2] && decoded.planes[3] == source.contiguous[3],
      "RGB identity channels and alpha preserved")
  }
  await test("bgr24ProductionAdapterSnapshotAndAVIFPreserveRGBChannels") {
    let width = 4
    let height = 2
    let stride = width * 3 + 4
    var bytes = [UInt8](repeating: 0xEE, count: stride * height)
    for row in 0..<height {
      for column in 0..<width {
        let offset = row * stride + column * 3
        bytes[offset] = UInt8(row * 23 + column * 7)
        bytes[offset + 1] = UInt8(64 + row * 11 + column * 13)
        bytes[offset + 2] = UInt8(240 - row * 19 - column * 17)
      }
    }
    let adapted = try bytes.withUnsafeBytes { raw in
      try FrameExtraction.adaptPackedRGB(
        data: raw.baseAddress!, bytesPerRow: stride,
        width: width, height: height, fourCC: PixelFormatFourCC.bgr24)
    }
    defer { for pointer in adapted.ownedStorage.compactMap({ $0 }) { pointer.deallocate() } }
    let expected = try CapturedCapture.snapshotPlanes(from: adapted)
    var capture = try makeCapture(makeBGRA())
    capture.fourCC = PixelFormatFourCC.bgr24
    capture.pixelFourCC = PixelFormatFourCC.bgr24
    capture.dataSource = .macDelivered
    capture.width = width
    capture.height = height
    capture.payload = .planes(expected)
    capture.color = CapturedCapture.ColorDescriptor(
      yuvRange: nil, primaries: 1, transfer: 13, matrix: 0,
      chromaLocation: nil, iccProfile: nil)
    try require(
      FrameExtraction.supportedPixelFormats.contains(PixelFormatFourCC.bgr24),
      "BGR24 is present in the shared production capability list")
    try require(
      expected.contiguous.count == 3 && expected.bitsPerChannel == 8,
      "BGR24 has three 8-bit channels")
    let restored = try JSONDecoder().decode(
      CapturedCapture.self, from: JSONEncoder().encode(capture))
    let result = try restored.encodeAVIF()
    let decoded = try LosslessAVIF.decode(encoded: result.data)
    try require(decoded.matrixCoefficients == 0, "BGR24 is encoded with identity RGB mapping")
    try require(
      decoded.planes == expected.contiguous, "BGR24 native channels survive the full archive path")
  }
  await test("unsupportedColorInterpretationsFailClosed") {
    let gammaBuffer = try makeNV12(fullRange: false)
    CVBufferSetAttachment(
      gammaBuffer, kCVImageBufferGammaLevelKey, NSNumber(value: 1.8), .shouldPropagate)
    do {
      _ = try makeCapture(gammaBuffer)
      throw CaptureFidelityTestError.assertion("standalone gamma accepted")
    } catch is CapturedCapture.SnapshotError {}

    let logBuffer = try makeNV12(fullRange: false)
    CVBufferSetAttachment(
      logBuffer, kCVImageBufferLogTransferFunctionKey, kCVImageBufferLogTransferFunction_AppleLog,
      .shouldPropagate)
    do {
      _ = try makeCapture(logBuffer)
      throw CaptureFidelityTestError.assertion("Apple Log accepted as unspecified CICP")
    } catch is CapturedCapture.SnapshotError {}

    let centerBuffer = try makeNV12(fullRange: false)
    CVBufferSetAttachment(
      centerBuffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
      .shouldPropagate)
    CVBufferSetAttachment(
      centerBuffer, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Center,
      .shouldPropagate)
    let centered = try makeCapture(centerBuffer)
    do {
      _ = try centered.encodeAVIF()
      throw CaptureFidelityTestError.assertion("unrepresentable center chroma accepted")
    } catch CapturedCapture.SnapshotError.unsupportedColorDescriptor {}
  }
}
