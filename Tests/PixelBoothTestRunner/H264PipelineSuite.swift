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

private func readH264FixtureSample() throws -> CMSampleBuffer {
  guard let url = Bundle.module.url(forResource: "h264-synthetic", withExtension: "264") else {
    throw H264PipelineTestError.setup("bundled H.264 fixture is missing")
  }
  let bytes = [UInt8](try Data(contentsOf: url))
  let nalUnits = annexBNALUnits(bytes)
  guard let sps = nalUnits.first(where: { $0.first.map { $0 & 0x1f } == 7 }),
    let pps = nalUnits.first(where: { $0.first.map { $0 & 0x1f } == 8 })
  else { throw H264PipelineTestError.setup("H.264 fixture lacks SPS/PPS") }
  let sampleNALs = nalUnits.filter {
    guard let header = $0.first else { return false }
    return header & 0x1f != 7 && header & 0x1f != 8
  }
  guard !sampleNALs.isEmpty else {
    throw H264PipelineTestError.setup("H.264 fixture has no picture")
  }

  var lengthPrefixed = Data()
  for nal in sampleNALs {
    var length = UInt32(nal.count).bigEndian
    withUnsafeBytes(of: &length) { lengthPrefixed.append(contentsOf: $0) }
    lengthPrefixed.append(contentsOf: nal)
  }
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
    duration: CMTime(value: 1, timescale: 30),
    presentationTimeStamp: CMTime(value: 1, timescale: 30), decodeTimeStamp: .invalid)
  var sampleSize = lengthPrefixed.count
  var sample: CMSampleBuffer?
  let sampleStatus = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
  guard sampleStatus == noErr, let sample else {
    throw H264PipelineTestError.setup("H.264 fixture sample buffer: \(sampleStatus)")
  }
  return sample
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
    let compressed = try readH264FixtureSample()
    let compressedDescription = try requireSampleDescription(compressed)
    let dimensions = CMVideoFormatDescriptionGetDimensions(compressedDescription)
    let source = DeliveredFrame(
      sampleBuffer: compressed, generation: 7, deviceUniqueID: "synthetic-h264-camera",
      fourCC: PixelFormatFourCC.avc1, width: Int(dimensions.width), height: Int(dimensions.height),
      timestampNanos: 33_333_333, hostMonotonicNanos: DispatchTime.now().uptimeNanoseconds,
      hostWallClockISO: "2026-09-26T15:00:00.000-05:00")
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
    try requireH264(outputs.count == 1, "single-frame H.264 fixture should reconstruct once")
    guard let decoded = outputs.first else {
      throw H264PipelineTestError.assertion("VideoToolbox returned no output")
    }
    let outputFourCC = CVPixelBufferGetPixelFormatType(decoded.pixelBuffer)
    try requireH264(
      FrameExtraction.supportedPixelFormats.contains(outputFourCC),
      "H.264 decoder output must route into a tested native-plane adapter")
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
    let savedCandidate = DeliveredFrame(
      sampleBuffer: decodedSample, generation: source.generation,
      deviceUniqueID: source.deviceUniqueID, fourCC: outputFourCC,
      width: CVPixelBufferGetWidth(decoded.pixelBuffer),
      height: CVPixelBufferGetHeight(decoded.pixelBuffer), timestampNanos: source.timestampNanos,
      hostMonotonicNanos: source.hostMonotonicNanos, hostWallClockISO: source.hostWallClockISO,
      sourceFourCC: PixelFormatFourCC.avc1, sourceSampleBuffer: compressed)
    let metadata = FrameMetadataSnapshot(
      mediaTimeNanos: source.timestampNanos,
      wallClockAnchorISO: source.hostWallClockISO, generation: source.generation)
    let capture = try CapturedCapture(from: savedCandidate, metadata: metadata)
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
}

private func requireSampleDescription(_ sample: CMSampleBuffer) throws -> CMFormatDescription {
  guard let description = CMSampleBufferGetFormatDescription(sample) else {
    throw H264PipelineTestError.setup("missing compressed format description")
  }
  return description
}
