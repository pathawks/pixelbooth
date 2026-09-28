// JPEG preservation tests (segment byte-exactness through metadata-only
// insertion, malformed rejection) and lossless AVIF round-trip tests
// (native-channel exactness, AOM selection, speed zero).

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothLibrary
import UniformTypeIdentifiers

// ---- JPEG fixtures ---------------------------------------------------------
/// A real decodable JPEG plus opaque metadata segments used to verify that the
/// archival parser preserves source coding and unknown metadata.
func jpegFixture(progressive: Bool = false, includeMetadata: Bool = true) -> [UInt8] {
  let width = 16
  let height = 16
  var pixels: [UInt8] = []
  pixels.reserveCapacity(width * height * 4)
  for y in 0..<height {
    for x in 0..<width {
      pixels.append(UInt8((x * 17 + y * 3) & 0xff))
      pixels.append(UInt8((y * 19 + x * 5) & 0xff))
      pixels.append(UInt8((x * 11 + y * 13) & 0xff))
      pixels.append(255)
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let image = CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let encoded = NSMutableData()
  let destination = CGImageDestinationCreateWithData(
    encoded, UTType.jpeg.identifier as CFString, 1, nil)!
  let properties: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.82,
    kCGImagePropertyJFIFIsProgressive: progressive,
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  precondition(CGImageDestinationFinalize(destination))
  var bytes = [UInt8](Data(referencing: encoded))

  func seg(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [
      0xFF, marker,
      UInt8(((payload.count + 2) >> 8) & 0xFF), UInt8((payload.count + 2) & 0xFF),
    ] + payload
  }
  if includeMetadata {
    let metadata =
      seg(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1] + [0x01, 0x02, 0x03, 0x04])
      + seg(0xE1, Array("Exif\0\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0])
      + seg(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8) + Array("<x:xmpmeta/>".utf8))
      + seg(0xED, Array("UnknownVendorSegmentPayload0123456789".utf8))
    bytes.insert(contentsOf: metadata, at: 2)
  }
  return bytes
}

/// One marker segment with its two-byte length field (`content` excludes it).
func jpegSegment(_ marker: UInt8, _ content: [UInt8]) -> [UInt8] {
  [
    0xFF, marker,
    UInt8(((content.count + 2) >> 8) & 0xFF), UInt8((content.count + 2) & 0xFF),
  ] + content
}

/// Real decodable JPEG: SOI, one APPn segment, standard frame and scan.
func minimalJPEG(appnMarker: UInt8, content: [UInt8]) -> [UInt8] {
  var bytes = jpegFixture(includeMetadata: false)
  bytes.insert(contentsOf: jpegSegment(appnMarker, content), at: 2)
  return bytes
}

private func compressedJPEGSample(_ bytes: [UInt8], fourCC: UInt32) throws -> CMSampleBuffer {
  var block: CMBlockBuffer?
  let status = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
    dataLength: bytes.count, flags: 0, blockBufferOut: &block)
  guard status == kCMBlockBufferNoErr, let block else {
    throw NSError(domain: "JPEGFixture", code: Int(status))
  }
  let replaceStatus = bytes.withUnsafeBytes { raw in
    CMBlockBufferReplaceDataBytes(
      with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
      dataLength: bytes.count)
  }
  guard replaceStatus == kCMBlockBufferNoErr else {
    throw NSError(domain: "JPEGFixture", code: Int(replaceStatus))
  }
  var format: CMFormatDescription?
  let formatStatus = CMFormatDescriptionCreate(
    allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Video,
    mediaSubType: fourCC, extensions: nil, formatDescriptionOut: &format)
  guard formatStatus == noErr, let format else {
    throw NSError(domain: "JPEGFixture", code: Int(formatStatus))
  }
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  let sampleStatus = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
  guard sampleStatus == noErr, let sample else {
    throw NSError(domain: "JPEGFixture", code: Int(sampleStatus))
  }
  return sample
}

func runJPEGSuite() async {
  suite("JPEGPreservation")

  await test("structureRoundTripsByteExact") {
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    check(parsed.reconstructedBytes() == original, "parse+rebuild must be byte-identical")
  }

  await test("metadataInsertionPreservesImageCoding") {
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: Array("<pbx:v1/>".utf8))
    let parsedAfter = try! JPEGParser.parse(withMeta)
    // Entropy-coded scan payload byte-identical.
    check(parsedAfter.scanAndEOI == parsed.scanAndEOI, "scan payload unchanged")
    // All original segments preserved (Exif, XMP, ICC, unknown APPn),
    // compared by marker + payload bytes (offsets necessarily shift).
    for seg in parsed.segments {
      check(
        parsedAfter.segments.contains { $0.marker == seg.marker && $0.payload == seg.payload },
        "original segment 0x\(String(seg.marker, radix: 16)) preserved")
    }
    // New XMP present.
    check(parsedAfter.xmpSegment != nil, "additional XMP inserted")
  }

  await test("unknownSegmentsSurvive") {
    let original = jpegFixture()
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: Array("x".utf8))
    let parsedAfter = try! JPEGParser.parse(withMeta)
    let parsedBefore = try! JPEGParser.parse(original)
    let originalAPP13 = parsedBefore.unknownAPPSegments.filter { $0.marker == 0xED }
    let afterAPP13 = parsedAfter.unknownAPPSegments.filter { $0.marker == 0xED }
    check(
      originalAPP13.allSatisfy { original in
        afterAPP13.contains {
          $0.marker == original.marker && $0.payload == original.payload
        }
      },
      "all source APP13 segments survive metadata insertion")
    check(
      afterAPP13.contains {
        String(decoding: $0.payload.dropFirst(2), as: UTF8.self)
          .contains("UnknownVendorSegmentPayload0123456789")
      },
      "opaque source vendor payload remains present")
  }

  await test("truncatedJPEGRejected") {
    var truncated = jpegFixture()
    truncated.removeLast(8)  // cut into scan data / EOI
    var thrown = false
    do { _ = try JPEGParser.parse(truncated) } catch { thrown = true }
    check(thrown, "truncated JPEG must be rejected")
  }

  await test("baselineAndProgressiveJPEGValidateAndDecode") {
    for progressive in [false, true] {
      let bytes = jpegFixture(progressive: progressive)
      let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil)
      let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
      check(decoded != nil, "baseline/progressive fixture must be decodable")
      do {
        let structure = try JPEGParser.parse(bytes)
        check(structure.scanAndEOI.count > 2, "complete scan data is retained")
      } catch {
        recordFailure("real JPEG rejected: \(error)")
      }
    }
  }

  await test("coreMediaJPEGTypesUseTheActualPassthroughPath") {
    let bytes = jpegFixture()
    for type in [PixelFormatFourCC.jpeg, PixelFormatFourCC.dmb1, PixelFormatFourCC.mjpeg] {
      do {
        let sample = try compressedJPEGSample(bytes, fourCC: type)
        let extracted = try FrameExtraction.extractJPEG(from: sample)
        check(extracted == bytes, "JPEG bytes survive the CMSampleBuffer path for \(type)")
        check(
          CaptureFormat(width: 16, height: 16, fourCC: type).codecFamily == .nativeJPEG,
          "codec classification shares the JPEG aliases")
      } catch {
        recordFailure("compressed JPEG FourCC \(type) failed: \(error)")
      }
    }
  }

  await test("malformedSOSAndMissingFrameAreRejected") {
    let impossible: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0xFF, 0xD9]
    let missingFrame: [UInt8] = [
      0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9,
    ]
    check((try? JPEGParser.parse(impossible)) == nil, "SOS without a length is rejected")
    check(
      (try? JPEGParser.parse(missingFrame)) == nil, "scan without a frame header is rejected")
  }

  await test("malformedHeaderRejected") {
    var bogus = jpegFixture()
    bogus[0] = 0x00  // not SOI
    var thrown = false
    do { _ = try JPEGParser.parse(bogus) } catch { thrown = true }
    check(thrown, "non-SOI rejected")
  }

  await test("shortExifAPP1SegmentsDoNotTrap") {
    // Regression: a length-6 APP1 payload ("Exif") passed the old
    // `payload.count >= 6` guard and then indexed payload[6], trapping.
    // The identifier is six bytes ("Exif\0\0"); shorter prefixes must parse
    // as unknown APP1 and survive byte-exact.
    let reportedRepro = minimalJPEG(appnMarker: 0xE1, content: Array("Exif".utf8))
    let repro = try! JPEGParser.parse(reportedRepro)
    let reportedPayload: [UInt8] = [0, 6] + Array("Exif".utf8)
    check(repro.exifSegment?.payload != reportedPayload, "length-6 APP1 is not Exif")
    check(
      repro.unknownAPPSegments.contains { $0.marker == 0xE1 && $0.payload == reportedPayload },
      "length-6 APP1 is preserved as unknown")
    check(repro.reconstructedBytes() == reportedRepro, "length-6 APP1 preserved byte-exact")

    let shortPrefixes: [[UInt8]] = [
      [],
      [0x45],
      [0x45, 0x78],
      [0x45, 0x78, 0x69],
      [0x45, 0x78, 0x69, 0x66],  // "Exif"
      [0x45, 0x78, 0x69, 0x66, 0x00],  // "Exif\0" — one terminator byte
    ]
    for (index, prefix) in shortPrefixes.enumerated() {
      do {
        let parsed = try JPEGParser.parse(minimalJPEG(appnMarker: 0xE1, content: prefix))
        let expectedPayload = [UInt8(0), UInt8(prefix.count + 2)] + prefix
        check(
          parsed.exifSegment?.payload != expectedPayload,
          "short prefix \(index) must not classify as Exif")
        check(
          parsed.unknownAPPSegments.contains {
            $0.marker == 0xE1 && $0.payload == expectedPayload
          },
          "short prefix \(index) is preserved as unknown")
      } catch {
        check(false, "short prefix \(index) must not throw, got \(error)")
      }
    }

    let completePayload: [UInt8] = [0, 8, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
    let complete = try! JPEGParser.parse(
      minimalJPEG(appnMarker: 0xE1, content: Array(completePayload.dropFirst(2))))
    check(
      complete.exifSegment?.payload == completePayload,
      "complete six-byte Exif identifier must be classified")

    let badTerminatorPayload: [UInt8] = [0, 8, 0x45, 0x78, 0x69, 0x66, 0x00, 0x01]
    let badTerminator = try! JPEGParser.parse(
      minimalJPEG(appnMarker: 0xE1, content: [0x45, 0x78, 0x69, 0x66, 0x00, 0x01]))
    check(
      badTerminator.exifSegment?.payload != badTerminatorPayload,
      "non-NUL second terminator must not classify as Exif")
  }

  await test("shortMetadataSegmentSweepDoesNotTrap") {
    // Every metadata probe (APP1 XMP/Exif, APP2 ICC) must bounds-check all
    // bytes it indexes. Sweep each signature prefix and require a byte-exact
    // round-trip of the short segment.
    let signatures: [(marker: UInt8, bytes: [UInt8])] = [
      (0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8)),
      (0xE1, Array("Exif\0\0".utf8)),
      (0xE2, Array("ICC_PROFILE\0".utf8)),
    ]
    for (marker, signature) in signatures {
      for length in 0...signature.count {
        let jpeg = minimalJPEG(appnMarker: marker, content: Array(signature.prefix(length)))
        do {
          let parsed = try JPEGParser.parse(jpeg)
          check(
            parsed.reconstructedBytes() == jpeg,
            "0x\(String(marker, radix: 16)) length \(length) preserved byte-exact")
        } catch {
          check(
            false, "0x\(String(marker, radix: 16)) length \(length) must not throw, got \(error)")
        }
      }
    }
  }

  await test("makerNotePayloadPreservedVerbatim") {
    // Source Exif with a MakerNotes-looking TIFF payload must survive verbatim.
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    let exif = parsed.exifSegment!
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: Array("z".utf8))
    let parsedAfter = try! JPEGParser.parse(withMeta)
    check(
      parsedAfter.exifSegment!.payload == exif.payload,
      "source Exif (incl. MakerNotes bytes) must not be rewritten")
  }
}

// ---- AVIF round-trip ---------------------------------------------------------
func gradientFixture(_ w: Int, _ h: Int, bytesPerSample: Int) -> (data: [UInt8], rowBytes: Int) {
  let bytesPerPixel = 3 * bytesPerSample
  let rowBytes = w * bytesPerPixel
  var data = [UInt8](repeating: 0, count: rowBytes * h)
  for y in 0..<h {
    for x in 0..<w {
      for c in 0..<3 {
        let value = (x * 29 + y * 61 + c * 101) % (1 << (8 * bytesPerSample))
        let offset = y * rowBytes + x * bytesPerPixel + c * bytesPerSample
        if bytesPerSample == 1 {
          data[offset] = UInt8(value)
        } else {
          data[offset] = UInt8(value & 0xFF)
          data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
      }
    }
  }
  return (data, rowBytes)
}

func runAVIFSuite() async {
  suite("AVIFRoundTrip")

  await test("rgbIdentityRoundTrip8Bit") {
    let (w, h) = (24, 16)
    let fixture = gradientFixture(w, h, bytesPerSample: 1)
    var data = fixture.data
    let planar = try! data.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptBGR24(
        data: raw.baseAddress!, bytesPerRow: fixture.rowBytes, width: w, height: h)
    }
    let (encoded, settings) = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil)
    check(settings.codec == "aom", "encoder must be AOM")
    check(settings.speed == 0, "speed must be zero")
    check(settings.quality == 100 && settings.qualityAlpha == 100, "lossless quality")
    let decoded = try! LosslessAVIF.decode(encoded: encoded)
    check(decoded.matrixCoefficients == 0, "identity matrix")
    check(decoded.range == 1, "full range")
  }

  await test("yuv420ExactNativeSamples") {
    let w = 16
    let h = 16
    var yPlane = [UInt8](repeating: 0, count: w * h)
    var chroma = [UInt8](repeating: 0, count: (w / 2) * (h / 2) * 2)
    for i in yPlane.indices { yPlane[i] = UInt8((i * 89) % 256) }
    for i in chroma.indices { chroma[i] = UInt8((i * 151) % 256) }
    let planar = try! yPlane.withUnsafeBytes { yp in
      try chroma.withUnsafeBytes { cp in
        try SampleLayoutAdapter.adaptNV12(
          yPlane: yp.baseAddress!, yBytesPerRow: w,
          chromaPlane: cp.baseAddress!, chromaBytesPerRow: w,
          width: w, height: h)
      }
    }
    let (encoded, _) = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: false, yuvRange: .full, chromaLocation: .left)
    // Native-channel comparison (YUV planes, never RGB renderings).
    let decoded = try! LosslessAVIF.decode(encoded: encoded)
    check(decoded.width == w && decoded.height == h, "geometry preserved")
    check(decoded.planes[0] == yPlane, "Y plane exact")
    var eu = [UInt8]()
    var ev = [UInt8]()
    for row in 0..<(h / 2) {
      for x in 0..<(w / 2) {
        eu.append(chroma[row * w + 2 * x])
        ev.append(chroma[row * w + 2 * x + 1])
      }
    }
    check(decoded.planes[1] == eu, "U plane exact")
    check(decoded.planes[2] == ev, "V plane exact")
  }

  await test("superblackSuperwhitePreserved") {
    let w = 8
    let h = 2
    var yPlane = [UInt8](repeating: 0, count: w * h)
    let chroma = [UInt8](repeating: 128, count: (w / 2) * (h / 2) * 2)
    for i in yPlane.indices { yPlane[i] = (i % 2 == 0) ? 0 : 255 }
    let planar = try! yPlane.withUnsafeBytes { yp in
      try chroma.withUnsafeBytes { cp in
        try SampleLayoutAdapter.adaptNV12(
          yPlane: yp.baseAddress!, yBytesPerRow: w,
          chromaPlane: cp.baseAddress!, chromaBytesPerRow: w,
          width: w, height: h)
      }
    }
    let (encoded, _) = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: false, yuvRange: .full, chromaLocation: nil)
    let decoded = try! LosslessAVIF.decode(encoded: encoded)
    check(decoded.planes[0] == yPlane, "storage extremes preserved exactly")
  }

  await test("oddDimensionsLegalFor444") {
    let w = 7
    let h = 5
    let fixture = gradientFixture(w, h, bytesPerSample: 1)
    var data = fixture.data
    let planar = try! data.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptBGR24(
        data: raw.baseAddress!, bytesPerRow: fixture.rowBytes, width: w, height: h)
    }
    _ = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil)
  }

  await test("codecNeverAutoSubstituted") {
    let fixture = gradientFixture(4, 4, bytesPerSample: 1)
    var data = fixture.data
    let planar = try! data.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptBGR24(
        data: raw.baseAddress!, bytesPerRow: fixture.rowBytes, width: 4, height: 4)
    }
    let (_, settings) = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil)
    check(settings.codec == "aom", "codec must be explicitly AOM after every encode")
  }
}
