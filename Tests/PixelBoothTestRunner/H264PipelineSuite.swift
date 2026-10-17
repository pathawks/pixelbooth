import CoreMedia
import CoreVideo
import Foundation
import PixelBoothAVIF
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata

private enum H264PipelineTestError: Error {
  case setup(String)
  case assertion(String)
}

private func requireH264(_ value: @autoclosure () -> Bool, _ message: String) throws {
  guard value() else { throw H264PipelineTestError.assertion(message) }
}

private struct H264FixtureStream {
  var formatDescription: CMFormatDescription
  var accessUnits: [[[UInt8]]]
}

private func readH264Fixture(_ name: String) throws -> H264FixtureStream {
  guard
    let url = Bundle.module.url(
      forResource: name, withExtension: "264", subdirectory: "Fixtures")
  else { throw H264PipelineTestError.setup("H.264 fixture \(name) is missing") }
  let bytes = [UInt8](try Data(contentsOf: url))
  let nalUnits = annexBNALUnits(bytes)
  guard let sps = nalUnits.first(where: { $0.first.map { $0 & 0x1f } == 7 }),
    let pps = nalUnits.first(where: { $0.first.map { $0 & 0x1f } == 8 })
  else { throw H264PipelineTestError.setup("H.264 fixture lacks SPS/PPS") }
  var format: CMFormatDescription?
  let formatStatus = sps.withUnsafeBytes { spsBytes in
    pps.withUnsafeBytes { ppsBytes in
      let pointers: [UnsafePointer<UInt8>] = [
        spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
      ]
      let sizes = [sps.count, pps.count]
      return pointers.withUnsafeBufferPointer { pointerBuffer in
        sizes.withUnsafeBufferPointer { sizeBuffer in
          CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: pointerBuffer.count,
            parameterSetPointers: pointerBuffer.baseAddress!,
            parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4,
            formatDescriptionOut: &format)
        }
      }
    }
  }
  guard formatStatus == noErr, let format else {
    throw H264PipelineTestError.setup("H.264 fixture format description: \(formatStatus)")
  }

  let hasAccessUnitDelimiters = nalUnits.contains { $0.first.map { $0 & 0x1f } == 9 }
  var accessUnits: [[[UInt8]]] = []
  var currentAccessUnit: [[UInt8]] = []
  for nal in nalUnits {
    guard let header = nal.first else { continue }
    let type = header & 0x1f
    if type == 7 || type == 8 { continue }
    if hasAccessUnitDelimiters, type == 9 {
      if currentAccessUnit.contains(where: isH264PictureNAL) {
        accessUnits.append(currentAccessUnit)
      }
      currentAccessUnit = [nal]
    } else if hasAccessUnitDelimiters {
      if !currentAccessUnit.isEmpty { currentAccessUnit.append(nal) }
    } else if type != 9 {
      currentAccessUnit.append(nal)
    }
  }
  if currentAccessUnit.contains(where: isH264PictureNAL) {
    accessUnits.append(currentAccessUnit)
  }
  guard !accessUnits.isEmpty else {
    throw H264PipelineTestError.setup("H.264 fixture has no picture access unit")
  }
  return H264FixtureStream(formatDescription: format, accessUnits: accessUnits)
}

private func isH264PictureNAL(_ nal: [UInt8]) -> Bool {
  guard let header = nal.first else { return false }
  return header & 0x1f == 1 || header & 0x1f == 5
}

private func makeH264Sample(
  accessUnit: [[UInt8]], formatDescription: CMFormatDescription,
  presentationIndex: Int, decodeIndex: Int, frameRate: Int32 = 30
) throws -> CMSampleBuffer {
  guard !accessUnit.isEmpty else { throw H264PipelineTestError.setup("empty H.264 access unit") }
  var lengthPrefixed = Data()
  for nal in accessUnit {
    guard let exactLength = UInt32(exactly: nal.count) else {
      throw H264PipelineTestError.setup("H.264 NAL is too large")
    }
    var length = exactLength.bigEndian
    withUnsafeBytes(of: &length) { lengthPrefixed.append(contentsOf: $0) }
    lengthPrefixed.append(contentsOf: nal)
  }
  var block: CMBlockBuffer?
  let blockStatus = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: lengthPrefixed.count,
    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
    dataLength: lengthPrefixed.count, flags: 0, blockBufferOut: &block)
  guard blockStatus == kCMBlockBufferNoErr, let block else {
    throw H264PipelineTestError.setup("H.264 fixture block buffer: \(blockStatus)")
  }
  let copyStatus = lengthPrefixed.withUnsafeBytes { raw in
    CMBlockBufferReplaceDataBytes(
      with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
      dataLength: lengthPrefixed.count)
  }
  guard copyStatus == kCMBlockBufferNoErr else {
    throw H264PipelineTestError.setup("H.264 fixture sample bytes: \(copyStatus)")
  }
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: frameRate),
    presentationTimeStamp: CMTime(value: Int64(presentationIndex), timescale: frameRate),
    decodeTimeStamp: CMTime(value: Int64(decodeIndex), timescale: frameRate))
  var sampleSize = lengthPrefixed.count
  var sample: CMSampleBuffer?
  let sampleStatus = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
  guard sampleStatus == noErr, let sample else {
    throw H264PipelineTestError.setup("H.264 fixture sample buffer: \(sampleStatus)")
  }
  return sample
}

private func readExpectedYUV(_ name: String) throws -> [UInt8] {
  guard
    let url = Bundle.module.url(forResource: name, withExtension: "yuv", subdirectory: "Fixtures")
  else { throw H264PipelineTestError.setup("independent H.264 reference \(name) is missing") }
  return [UInt8](try Data(contentsOf: url))
}

private func annexBNALUnits(_ bytes: [UInt8]) -> [[UInt8]] {
  func prefixLength(at index: Int) -> Int {
    guard index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0 else { return 0 }
    if bytes[index + 2] == 1 { return 3 }
    if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 { return 4 }
    return 0
  }
  var starts: [(index: Int, length: Int)] = []
  var index = 0
  while index < bytes.count {
    let prefix = prefixLength(at: index)
    if prefix > 0 {
      starts.append((index, prefix))
      index += prefix
    } else {
      index += 1
    }
  }
  return starts.enumerated().compactMap { position, start in
    let payloadStart = start.index + start.length
    let nextStart = position + 1 < starts.count ? starts[position + 1].index : bytes.count
    guard payloadStart < nextStart else { return nil }
    var end = nextStart
    while end > payloadStart, bytes[end - 1] == 0 { end -= 1 }
    return payloadStart < end ? Array(bytes[payloadStart..<end]) : nil
  }
}

func runH264PipelineSuite() async {
  suite("H264DecodeToNativeAVIF")
  await test("encodedH264DecodesAndOnlyReconstructedSamplesEnterAVIF") {
    let stream = try readH264Fixture("h264-synthetic")
    guard let accessUnit = stream.accessUnits.first else {
      throw H264PipelineTestError.setup("single-frame H.264 fixture has no access unit")
    }
    let compressed = try makeH264Sample(
      accessUnit: accessUnit, formatDescription: stream.formatDescription,
      presentationIndex: 1, decodeIndex: 1)
    let compressedDescription = stream.formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(compressedDescription)
    let source = makeSourceFrame(
      sample: compressed, dimensions: dimensions, presentationIndex: 1)
    let decoder = H264VideoToolboxStreamDecoder()
    defer { decoder.invalidate() }
    let outputs: [H264VideoToolboxStreamDecoder.DecodedOutput]
    do {
      outputs = try decoder.decode(source)
    } catch H264VideoToolboxStreamDecoder.DecodeError.sessionCreation(let status)
      where status == -12911
    {
      try skipTest(
        "VideoToolbox returned kVTVideoDecoderMalfunctionErr (-12911) creating a session on this host; the H.264 fixture parses, but decoder-to-AVIF acceptance remains unverified"
      )
    }
    let completedOutputs = outputs.isEmpty ? try decoder.finishDelayedFrames() : outputs
    try requireH264(
      completedOutputs.count == 1, "single-frame H.264 fixture should reconstruct once")
    guard let decoded = completedOutputs.first else {
      throw H264PipelineTestError.assertion("VideoToolbox returned no output")
    }
    let outputFourCC = CVPixelBufferGetPixelFormatType(decoded.pixelBuffer)
    try requireH264(
      outputFourCC == PixelFormatFourCC.fourTwentyV,
      "unsignaled H.264 range uses the standards-inferred limited-range pixel format")
    let capture = try makeCapture(decoded, generation: source.generation)
    try requireH264(capture.fourCC == PixelFormatFourCC.avc1, "source codec stays in provenance")
    try requireH264(
      capture.pixelFourCC == outputFourCC && capture.dataSource == .macDecoded,
      "reconstructed pixel layout and decoder provenance stay distinct from H.264 source")
    guard case .planes(let snapshot) = capture.payload else {
      throw H264PipelineTestError.assertion("compressed H.264 bytes must not be archived")
    }
    let encoded = try capture.encodeAVIF()
    let roundTrip = try LosslessAVIF.decode(encoded: encoded.data)
    try requireH264(
      roundTrip.width == capture.width && roundTrip.height == capture.height,
      "reconstructed dimensions stay unchanged in AVIF")
    try requireH264(
      roundTrip.planes[0] == snapshot.contiguous[0]
        && roundTrip.planes[1] == snapshot.contiguous[1]
        && roundTrip.planes[2] == snapshot.contiguous[2],
      "AVIF decoder returns the exact VideoToolbox-reconstructed YUV planes")
  }

  await test("fullAndLimitedRangeDecodeMatchIndependentReconstruction") {
    let cases: [(String, H264SourceRepresentation.Range, UInt32)] = [
      ("h264-limited-range", .limited, PixelFormatFourCC.fourTwentyV),
      ("h264-full-range", .full, PixelFormatFourCC.fourTwentyF),
    ]
    for (name, expectedRange, expectedPixelFormat) in cases {
      let stream = try readH264Fixture(name)
      let sourceDescription = try H264SourceRepresentation.inspect(
        formatDescription: stream.formatDescription)
      try requireH264(sourceDescription.range == expectedRange, "\(name) range comes from its SPS")
      try sourceDescription.validateForArchival()
      guard let accessUnit = stream.accessUnits.first else {
        throw H264PipelineTestError.setup("\(name) has no picture access unit")
      }
      let sample = try makeH264Sample(
        accessUnit: accessUnit, formatDescription: stream.formatDescription,
        presentationIndex: 0, decodeIndex: 0)
      let dimensions = CMVideoFormatDescriptionGetDimensions(stream.formatDescription)
      let source = makeSourceFrame(sample: sample, dimensions: dimensions, presentationIndex: 0)
      let decoder = H264VideoToolboxStreamDecoder()
      defer { decoder.invalidate() }
      let decodedOutputs: [H264VideoToolboxStreamDecoder.DecodedOutput]
      do {
        decodedOutputs = try decoder.decode(source)
      } catch H264VideoToolboxStreamDecoder.DecodeError.sessionCreation(let status)
        where status == -12911
      {
        try skipTest(
          "VideoToolbox returned kVTVideoDecoderMalfunctionErr (-12911) creating a session on this host; source SPS validation passed, but reconstructed samples could not be verified"
        )
      }
      let outputs = decodedOutputs.isEmpty ? try decoder.finishDelayedFrames() : decodedOutputs
      guard let output = outputs.first else {
        throw H264PipelineTestError.assertion("VideoToolbox returned no \(name) output")
      }
      try requireH264(
        CVPixelBufferGetPixelFormatType(output.pixelBuffer) == expectedPixelFormat,
        "VideoToolbox output range matches \(name) source range")
      let capture = try makeCapture(output, generation: source.generation)
      let actual = try yuvPlanes(capture)
      let expected = try readExpectedYUV(name)
      try requireH264(
        expected.count == 384, "\(name) independent reference is one 16×16 YUV420 frame")
      try requireH264(
        actual == [
          Array(expected[0..<256]), Array(expected[256..<320]), Array(expected[320..<384]),
        ],
        "\(name) VideoToolbox reconstruction matches FFmpeg's independent native YUV output")
    }
  }

  await test("unsupportedDepthSamplingAndFieldStructureAreRejectedBeforeDecode") {
    let cases: [(String, UInt32, UInt32, Bool)] = [
      ("h264-10bit", 1, 10, true),
      ("h264-422", 2, 8, true),
      ("h264-interlaced", 1, 8, false),
    ]
    for (name, expectedChroma, expectedDepth, expectedProgressive) in cases {
      let stream = try readH264Fixture(name)
      let representation = try H264SourceRepresentation.inspect(
        formatDescription: stream.formatDescription)
      try requireH264(
        representation.chromaFormatIDC == expectedChroma,
        "\(name) reports SPS chroma_format_idc")
      try requireH264(
        representation.bitDepthLuma == expectedDepth
          && representation.bitDepthChroma == expectedDepth,
        "\(name) reports SPS luma and chroma precision")
      try requireH264(
        representation.isProgressive == expectedProgressive,
        "\(name) reports SPS frame/field structure")
      do {
        try representation.validateForArchival()
        throw H264PipelineTestError.assertion("unsupported \(name) source was accepted")
      } catch H264SourceRepresentation.Error.unsupportedRepresentation {
        // Expected: these layouts have no verified matching output adapter.
      }
    }
  }

  await test("multiFrameReferenceDependenciesReturnPresentationOrderSamples") {
    let stream = try readH264Fixture("h264-reordered")
    try requireH264(stream.accessUnits.count == 5, "the fixture contains five access units")
    let representation = try H264SourceRepresentation.inspect(
      formatDescription: stream.formatDescription)
    try representation.validateForArchival()
    // libx264's coded order is I, P, B, B, P; sample PTS follows display order.
    let presentationIndexByDecodeOrder = [0, 3, 1, 2, 4]
    let dimensions = CMVideoFormatDescriptionGetDimensions(stream.formatDescription)
    let decoder = H264VideoToolboxStreamDecoder()
    defer { decoder.invalidate() }
    var outputs: [H264VideoToolboxStreamDecoder.DecodedOutput] = []
    for (decodeIndex, accessUnit) in stream.accessUnits.enumerated() {
      let presentationIndex = presentationIndexByDecodeOrder[decodeIndex]
      let sample = try makeH264Sample(
        accessUnit: accessUnit, formatDescription: stream.formatDescription,
        presentationIndex: presentationIndex, decodeIndex: decodeIndex)
      let source = makeSourceFrame(
        sample: sample, dimensions: dimensions, presentationIndex: presentationIndex)
      do {
        outputs.append(contentsOf: try decoder.decode(source))
      } catch H264VideoToolboxStreamDecoder.DecodeError.sessionCreation(let status)
        where status == -12911
      {
        try skipTest(
          "VideoToolbox returned kVTVideoDecoderMalfunctionErr (-12911) creating a session on this host; multi-frame reconstruction and presentation ordering remain unverified"
        )
      }
    }
    outputs.append(contentsOf: try decoder.finishDelayedFrames())
    try requireH264(outputs.count == 5, "reference and reordering dependencies produce all frames")
    let outputIndices = outputs.map {
      Int(CMTimeConvertScale($0.presentationTimeStamp, timescale: 30, method: .default).value)
    }
    try requireH264(
      Set(outputIndices) == Set(0..<5),
      "all reconstructed output timestamps preserve their input presentation identities")
    outputs.sort {
      CMTimeCompare($0.presentationTimeStamp, $1.presentationTimeStamp) < 0
    }
    let presentationIndices = outputs.map {
      Int(CMTimeConvertScale($0.presentationTimeStamp, timescale: 30, method: .default).value)
    }
    try requireH264(
      presentationIndices == Array(0..<5), "reordered output timestamps sort into display order")
    let expected = try readExpectedYUV("h264-reordered")
    try requireH264(expected.count == 5 * 384, "independent reference contains five YUV frames")
    for (index, output) in outputs.enumerated() {
      let capture = try makeCapture(output, generation: output.sourceFrame.generation)
      let expectedFrameStart = index * 384
      let expectedFrame = Array(expected[expectedFrameStart..<(expectedFrameStart + 384)])
      let expectedPlanes = [
        Array(expectedFrame[0..<256]), Array(expectedFrame[256..<320]),
        Array(expectedFrame[320..<384]),
      ]
      let actualPlanes = try yuvPlanes(capture)
      try requireH264(
        actualPlanes == expectedPlanes,
        "presentation frame \(index) matches FFmpeg's independent reconstructed samples")
    }
  }
}

private func makeSourceFrame(
  sample: CMSampleBuffer, dimensions: CMVideoDimensions, presentationIndex: Int
) -> DeliveredFrame {
  DeliveredFrame(
    sampleBuffer: sample, generation: 7, deviceUniqueID: "synthetic-h264-camera",
    fourCC: PixelFormatFourCC.avc1, width: Int(dimensions.width), height: Int(dimensions.height),
    timestampNanos: UInt64(max(presentationIndex, 0)) * 33_333_333,
    hostMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
    hostWallClockISO: "2026-10-12T12:00:00Z")
}

private func makeCapture(
  _ decoded: H264VideoToolboxStreamDecoder.DecodedOutput, generation: Int
) throws -> CapturedCapture {
  var imageDescription: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: decoded.pixelBuffer,
      formatDescriptionOut: &imageDescription) == noErr, let imageDescription
  else { throw H264PipelineTestError.setup("decoded image description") }
  var timing = CMSampleTimingInfo(
    duration: decoded.duration, presentationTimeStamp: decoded.presentationTimeStamp,
    decodeTimeStamp: .invalid)
  var decodedSample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: decoded.pixelBuffer,
      formatDescription: imageDescription, sampleTiming: &timing, sampleBufferOut: &decodedSample)
      == noErr,
    let decodedSample
  else { throw H264PipelineTestError.setup("decoded image sample") }
  let source = decoded.sourceFrame
  let savedCandidate = DeliveredFrame(
    sampleBuffer: decodedSample, generation: source.generation,
    deviceUniqueID: source.deviceUniqueID,
    fourCC: CVPixelBufferGetPixelFormatType(decoded.pixelBuffer),
    width: CVPixelBufferGetWidth(decoded.pixelBuffer),
    height: CVPixelBufferGetHeight(decoded.pixelBuffer),
    timestampNanos: source.timestampNanos, hostMonotonicNanos: source.hostMonotonicNanos,
    hostWallClockISO: source.hostWallClockISO, sourceFourCC: PixelFormatFourCC.avc1,
    sourceSampleBuffer: source.sampleBuffer)
  let metadata = FrameMetadataSnapshot(
    mediaTimeNanos: source.timestampNanos, wallClockAnchorISO: source.hostWallClockISO,
    generation: generation)
  return try CapturedCapture(from: savedCandidate, metadata: metadata)
}

private func yuvPlanes(_ capture: CapturedCapture) throws -> [[UInt8]] {
  guard case .planes(let snapshot) = capture.payload else {
    throw H264PipelineTestError.assertion("decoded frame did not retain native YUV planes")
  }
  return snapshot.contiguous.map { [UInt8]($0) }
}

private func requireSampleDescription(_ sample: CMSampleBuffer) throws -> CMFormatDescription {
  guard let description = CMSampleBufferGetFormatDescription(sample) else {
    throw H264PipelineTestError.setup("missing compressed format description")
  }
  return description
}
