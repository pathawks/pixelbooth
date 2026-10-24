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
import PixelBoothCapture
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothLibrary
import PixelBoothMetadata
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
  if progressive {
    let progressiveURL = Bundle.module.url(
      forResource: "jpeg-progressive", withExtension: "jpg", subdirectory: "Fixtures")!
    bytes = [UInt8](try! Data(contentsOf: progressiveURL))
  }

  func seg(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [
      0xFF, marker,
      UInt8(((payload.count + 2) >> 8) & 0xFF), UInt8((payload.count + 2) & 0xFF),
    ] + payload
  }
  if includeMetadata {
    let sourceXMP = """
      <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:cam="urn:camera:source" xmlns:exif="http://ns.adobe.com/exif/1.0/" dc:description="Camera source description" cam:CalibrationValue="camera calibration" exif:GPSLatitude="12,30N"/>
      </rdf:RDF>
      </x:xmpmeta>
      <?xpacket end="w"?>
      """
    let metadata =
      seg(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1] + [0x01, 0x02, 0x03, 0x04])
      + seg(0xE1, sourceExifWithMakerNote())
      + seg(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8) + Array(sourceXMP.utf8))
      + seg(0xED, Array("UnknownVendorSegmentPayload0123456789".utf8))
    bytes.insert(contentsOf: metadata, at: 2)
  }
  return bytes
}

private func sourceExifWithMakerNote() -> [UInt8] {
  let makerNote = Array("VendorMakerNote".utf8) + [0x00, 0x01, 0xFE]
  var tiff: [UInt8] = [
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,  // Little-endian TIFF header.
    0x01, 0x00,  // One IFD0 entry.
    0x7C, 0x92, 0x07, 0x00,  // MakerNote, UNDEFINED.
    UInt8(makerNote.count), 0x00, 0x00, 0x00,
    0x1A, 0x00, 0x00, 0x00,  // TIFF-relative offset 26.
    0x00, 0x00, 0x00, 0x00,  // No next IFD.
  ]
  tiff.append(contentsOf: makerNote)
  return Array("Exif\0\0".utf8) + tiff
}

private func sampleApplicationXMP(
  captureUUID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
  hostLocation: HostLocationObservation? = nil
) -> [UInt8] {
  PixelBoothXMP.build(
    captureUUID: captureUUID, appVersion: "1.0", captureBackend: "AVFoundation",
    backendVersion: "macOS", libavifVersion: "test", actualCaptureFormat: "MJPG 16×16",
    encoderSettings: "lossless", metadataProvenance: [], fidelity: "unknown",
    hostLocation: hostLocation, mediaTimeNanos: 1,
    wallClockAnchorISO: "2026-10-12T12:00:00Z")
}

private func isJPEGXMP(_ segment: JPEGSegment) -> Bool {
  guard segment.marker == 0xE1, segment.payload.count >= 2 else { return false }
  let content = Array(segment.payload.dropFirst(2))
  return content.starts(with: Array("http://ns.adobe.com/xap/1.0/\0".utf8))
    || content.starts(with: Array("http://ns.adobe.com/xmp/extension/\0".utf8))
}

private func isJPEGStandardXMP(_ segment: JPEGSegment) -> Bool {
  guard segment.marker == 0xE1, segment.payload.count >= 2 else { return false }
  return Array(segment.payload.dropFirst(2))
    .starts(with: Array("http://ns.adobe.com/xap/1.0/\0".utf8))
}

private func isJPEGExtendedXMP(_ segment: JPEGSegment) -> Bool {
  guard segment.marker == 0xE1, segment.payload.count >= 2 else { return false }
  return Array(segment.payload.dropFirst(2))
    .starts(with: Array("http://ns.adobe.com/xmp/extension/\0".utf8))
}

private func firstMarkerAfterEntropy(in scan: [UInt8]) -> Int? {
  guard scan.count >= 6, scan[0] == 0xFF, scan[1] == 0xDA else { return nil }
  let length = (Int(scan[2]) << 8) | Int(scan[3])
  guard length >= 2, length <= scan.count - 2 else { return nil }
  var index = 2 + length
  var sawEntropy = false
  while index < scan.count {
    guard scan[index] == 0xFF else {
      sawEntropy = true
      index += 1
      continue
    }
    let markerStart = index
    while index < scan.count, scan[index] == 0xFF { index += 1 }
    guard index < scan.count else { return nil }
    let marker = scan[index]
    if marker == 0x00 || (0xD0...0xD7).contains(marker) {
      sawEntropy = true
      index += 1
      continue
    }
    return sawEntropy ? markerStart : nil
  }
  return nil
}

private func imageIOMetadataValue(_ jpeg: [UInt8], path: String) -> String? {
  guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
    let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
    let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString)
  else { return nil }
  return String(describing: value)
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

private func compressedJPEGSample(
  _ bytes: [UInt8], fourCC: UInt32, formatExtensions: [CFString: Any]? = nil
) throws -> CMSampleBuffer {
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
    mediaSubType: fourCC, extensions: formatExtensions as CFDictionary?,
    formatDescriptionOut: &format)
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

  await test("compressed JPEG preview decodes a display copy and keeps source bytes") {
    let sourceBytes = jpegFixture(includeMetadata: false)
    let sample = try! compressedJPEGSample(sourceBytes, fourCC: PixelFormatFourCC.mjpeg)
    let frame = DeliveredFrame(
      sampleBuffer: sample, generation: 4, deviceUniqueID: "preview-camera",
      fourCC: PixelFormatFourCC.mjpeg, width: 16, height: 16, timestampNanos: 1,
      hostMonotonicNanos: 1, hostWallClockISO: "2026-10-12T00:00:00Z")
    check(
      frame.previewRoute == .decodeJPEG,
      "compressed JPEG without a pixel buffer uses display decode")
    let image = CompressedPreviewDecoder.decodeJPEG(sampleBuffer: sample)
    check(image?.width == 16 && image?.height == 16, "ImageIO decodes a bounded preview image")

    let block = CMSampleBufferGetDataBuffer(sample)!
    var copied = Data(count: sourceBytes.count)
    let status = copied.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: sourceBytes.count, destination: bytes.baseAddress!)
    }
    check(status == kCMBlockBufferNoErr, "source JPEG sample remains readable after preview")
    check(Array(copied) == sourceBytes, "preview decoding leaves JPEG coding bytes unchanged")

    let h264Sample = try! compressedJPEGSample(sourceBytes, fourCC: PixelFormatFourCC.avc1)
    let h264Frame = DeliveredFrame(
      sampleBuffer: h264Sample, generation: 4, deviceUniqueID: "preview-camera",
      fourCC: PixelFormatFourCC.avc1, width: 16, height: 16, timestampNanos: 1,
      hostMonotonicNanos: 1, hostWallClockISO: "2026-10-12T00:00:00Z")
    check(
      h264Frame.previewRoute == .decodeH264,
      "compressed H.264 preview is sourced from the archival decoder output")
  }

  await test("structureRoundTripsByteExact") {
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    check(parsed.reconstructedBytes() == original, "parse+rebuild must be byte-identical")
  }

  await test("metadataInsertionPreservesImageCoding") {
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: sampleApplicationXMP())
    let parsedAfter = try! JPEGParser.parse(withMeta)
    // Entropy-coded scan payload byte-identical.
    check(parsedAfter.scanAndEOI == parsed.scanAndEOI, "scan payload unchanged")
    let codingMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xDB, 0xC4, 0xDD]
    let codingBefore = parsed.segments.filter { codingMarkers.contains($0.marker) }
      .map { (marker: $0.marker, payload: $0.payload) }
    let codingAfter = parsedAfter.segments.filter { codingMarkers.contains($0.marker) }
      .map { (marker: $0.marker, payload: $0.payload) }
    check(
      codingAfter.count == codingBefore.count
        && zip(codingAfter, codingBefore).allSatisfy {
          $0.0.marker == $0.1.marker && $0.0.payload == $0.1.payload
        },
      "frame and coding-table segments remain byte-identical")
    // Exif, ICC and opaque APPn data stay byte-exact. XMP is merged into one
    // reader-visible packet and is checked semantically in dedicated tests.
    for seg in parsed.segments where !isJPEGXMP(seg) {
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
      original: original, additionalXMP: sampleApplicationXMP())
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

  await test("missingAndMalformedCodingTablesAreRejected") {
    let original = jpegFixture(progressive: false)
    let parsed = try! JPEGParser.parse(original)
    func rebuilding(_ source: JPEGStructure, removing markers: Set<UInt8>) -> [UInt8] {
      var result: [UInt8] = [0xFF, 0xD8]
      for segment in source.segments where !markers.contains(segment.marker) {
        result.append(contentsOf: [0xFF, segment.marker])
        result.append(contentsOf: segment.payload)
      }
      result.append(contentsOf: source.scanAndEOI)
      return result
    }

    let noHuffmanTables = rebuilding(parsed, removing: [0xC4])
    check(
      (try? JPEGParser.parse(noHuffmanTables)) == nil,
      "baseline JPEG with every DHT removed cannot be finalized")
    let noQuantizationTables = rebuilding(parsed, removing: [0xDB])
    check(
      (try? JPEGParser.parse(noQuantizationTables)) == nil,
      "a scan cannot reference missing DQT definitions")

    guard let firstHuffman = parsed.segments.first(where: { $0.marker == 0xC4 }) else {
      recordFailure("baseline fixture should contain DHT")
      return
    }
    var malformed = original
    // The first count is the number of one-bit codes. Three codes oversubscribe
    // the one-bit code space and must be rejected before any image decoding.
    malformed[firstHuffman.offset + 5] = 3
    check(
      (try? JPEGParser.parse(malformed)) == nil,
      "oversubscribed Huffman definition is rejected")
  }

  await test("progressiveJPEGAllowsHuffmanTableRedefinitionBetweenScans") {
    let original = jpegFixture(progressive: true)
    let parsed = try! JPEGParser.parse(original)
    guard let huffman = parsed.segments.first(where: { $0.marker == 0xC4 }),
      let boundary = firstMarkerAfterEntropy(in: parsed.scanAndEOI)
    else {
      recordFailure("progressive fixture should expose a post-scan marker and DHT")
      return
    }
    var scan = parsed.scanAndEOI
    let duplicate: [UInt8]
    if boundary + 4 <= scan.count, scan[boundary] == 0xFF, scan[boundary + 1] == 0xC4 {
      let length = (Int(scan[boundary + 2]) << 8) | Int(scan[boundary + 3])
      let end = boundary + 2 + length
      guard length >= 2, end <= scan.count else {
        recordFailure("progressive DHT redefinition segment is malformed")
        return
      }
      duplicate = Array(scan[boundary..<end])
    } else {
      duplicate = [UInt8(0xFF), huffman.marker] + huffman.payload
    }
    scan.insert(contentsOf: duplicate, at: boundary)
    let boundaryMarker =
      boundary + 1 < parsed.scanAndEOI.count
      ? parsed.scanAndEOI[boundary + 1] : 0
    var redefined = [UInt8(0xFF), 0xD8]
    for segment in parsed.segments {
      redefined.append(contentsOf: [0xFF, segment.marker])
      redefined.append(contentsOf: segment.payload)
    }
    redefined.append(contentsOf: scan)
    do {
      _ = try JPEGParser.parse(redefined)
      let source = CGImageSourceCreateWithData(Data(redefined) as CFData, nil)
      check(
        source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil,
        "independent ImageIO decoding accepts the redefined progressive tables")
    } catch {
      recordFailure(
        "valid progressive table redefinition rejected before marker 0x\(String(boundaryMarker, radix: 16)): \(error)"
      )
    }
  }

  await test("JPEGXMPSourceApplicationMergeAndConflictsAreReaderVisible") {
    let sourceJPEG = jpegFixture()
    check(
      imageIOMetadataValue(sourceJPEG, path: "dc:description")
        == "Camera source description",
      "native ImageIO sees the source camera description")
    check(
      imageIOMetadataValue(sourceJPEG, path: "cam:CalibrationValue")
        == "camera calibration",
      "native ImageIO sees unknown source namespace properties")

    let appOnly = try JPEGMetadataWriter.withAdditionalMetadata(
      original: jpegFixture(includeMetadata: false), additionalXMP: sampleApplicationXMP())
    check(
      imageIOMetadataValue(appOnly, path: "pbx:CaptureUUID")
        == "11111111-2222-3333-4444-555555555555",
      "native ImageIO sees application-only provenance")

    let location = HostLocationObservation(
      latitude: 47.6062, longitude: -122.3321, altitude: nil,
      horizontalAccuracy: 5, verticalAccuracy: nil,
      timestampISO: "2026-10-12T12:00:00Z", ageAtCaptureSeconds: 1)
    let merged = try JPEGMetadataWriter.withAdditionalMetadata(
      original: sourceJPEG, additionalXMP: sampleApplicationXMP(hostLocation: location))
    let mergedStructure = try JPEGParser.parse(merged)
    let standardXMPCount = mergedStructure.segments.filter(isJPEGStandardXMP).count
    check(standardXMPCount == 1, "merged JPEG has one standard XMP primary packet")
    check(
      imageIOMetadataValue(merged, path: "dc:description") == "Camera source description",
      "source dc:description remains visible")
    check(
      imageIOMetadataValue(merged, path: "cam:CalibrationValue") == "camera calibration",
      "unknown source properties remain visible")
    check(
      imageIOMetadataValue(merged, path: "pbx:CaptureUUID")
        == "11111111-2222-3333-4444-555555555555",
      "application provenance is visible in the same reader-visible packet")
    check(
      imageIOMetadataValue(merged, path: "exif:GPSLatitude") == "12,30N",
      "source camera GPS wins over the conflicting host geotag")
    check(
      imageIOMetadataValue(merged, path: "pbx:HostLatitude") == "47.6062",
      "host observation remains separately recorded with its provenance")
    let originalStructure = try JPEGParser.parse(sourceJPEG)
    check(mergedStructure.scanAndEOI == originalStructure.scanAndEOI, "merged scan stays exact")
    let mergedCoding = mergedStructure.segments.filter {
      $0.marker == 0xC0 || $0.marker == 0xC4 || $0.marker == 0xDB
    }
    let originalCoding = originalStructure.segments.filter {
      $0.marker == 0xC0 || $0.marker == 0xC4 || $0.marker == 0xDB
    }
    check(
      mergedCoding.count == originalCoding.count
        && zip(mergedCoding, originalCoding).allSatisfy {
          $0.0.marker == $0.1.marker && $0.0.payload == $0.1.payload
        },
      "JPEG frame and coding tables remain byte-identical")
    check(
      mergedStructure.exifSegment?.payload == originalStructure.exifSegment?.payload,
      "source Exif and MakerNotes bytes remain byte-identical")
  }

  await test("extendedJPEGXMPIsChunkedMergedAndVisibleToImageIO") {
    let largeNote = String(repeating: "x", count: 70_000)
    let packet = String(bytes: sampleApplicationXMP(), encoding: .utf8)!.replacingOccurrences(
      of: "</rdf:Description>",
      with: "<pbx:LargeNote>\(largeNote)</pbx:LargeNote></rdf:Description>")
    let firstWrite = try JPEGMetadataWriter.withAdditionalMetadata(
      original: jpegFixture(), additionalXMP: Array(packet.utf8))
    let firstStructure = try JPEGParser.parse(firstWrite)
    check(
      firstStructure.segments.contains(where: isJPEGExtendedXMP),
      "large merged XMP is stored in standard extended-XMP APP1 chunks")
    let secondWrite = try JPEGMetadataWriter.withAdditionalMetadata(
      original: firstWrite, additionalXMP: sampleApplicationXMP())
    check(
      imageIOMetadataValue(secondWrite, path: "pbx:LargeNote") == largeNote,
      "native ImageIO reads the reassembled extended application property")
    check(
      imageIOMetadataValue(secondWrite, path: "cam:CalibrationValue") == "camera calibration",
      "source metadata survives re-merging an existing extended packet")
  }

  await test("malformedAndUnsafeJPEGXMPIsRejected") {
    for packet in [
      Array("<x:xmpmeta".utf8),
      Array("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x:xmpmeta/>".utf8),
    ] {
      do {
        _ = try JPEGMetadataWriter.withAdditionalMetadata(
          original: jpegFixture(includeMetadata: false), additionalXMP: packet)
        recordFailure("malformed or entity-bearing XMP was accepted")
      } catch JPEGError.metadataInsertionFailed {
        // Expected: source metadata is left untouched unless a bounded merge succeeds.
      }
    }
    let oversized = String(bytes: sampleApplicationXMP(), encoding: .utf8)!.replacingOccurrences(
      of: "</rdf:Description>",
      with:
        "<pbx:Oversized>\(String(repeating: "x", count: 4_200_000))</pbx:Oversized></rdf:Description>"
    )
    do {
      _ = try JPEGMetadataWriter.withAdditionalMetadata(
        original: jpegFixture(includeMetadata: false), additionalXMP: Array(oversized.utf8))
      recordFailure("XMP beyond the safety bound was accepted")
    } catch JPEGError.metadataInsertionFailed {
      // Expected: oversize is a strict refusal, not a partial packet.
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

  await test("acceptedJPEGCapturesRetainCodingBytesForEveryAlias") {
    let bytes = jpegFixture()
    let selected = CaptureFormat(width: 16, height: 16, fourCC: PixelFormatFourCC.mjpeg)
    let sourceCoding = try JPEGParser.parse(bytes)
    for type in [PixelFormatFourCC.mjpeg, PixelFormatFourCC.jpeg, PixelFormatFourCC.dmb1] {
      let sample = try compressedJPEGSample(bytes, fourCC: type)
      let frame = DeliveredFrame(
        sampleBuffer: sample, generation: 1, deviceUniqueID: "jpeg-fixture",
        fourCC: type, width: 16, height: 16, timestampNanos: 1,
        hostMonotonicNanos: 1, hostWallClockISO: "2026-10-12T12:00:00Z")
      let evidence = try AcquisitionPolicy.evaluate(
        deviceUniqueID: "jpeg-fixture", generation: 1,
        expectedDeviceID: "jpeg-fixture", expectedGeneration: 1,
        selected: selected, delivered: CaptureFormat(width: 16, height: 16, fourCC: type))
      let metadata = FrameMetadataSnapshot(
        mediaTimeNanos: 1, wallClockAnchorISO: "2026-10-12T12:00:00Z", generation: 1)
      let capture = try CapturedCapture(
        from: frame, metadata: metadata, acquisitionEvidence: evidence)
      guard case .jpegBytes(let retained) = capture.payload else {
        recordFailure("accepted JPEG mode did not retain a JPEG payload")
        continue
      }
      check(retained == bytes, "JPEG image-coding bytes remain byte-exact for \(type)")
      let archivedSegments =
        capture.metadata.attachmentArchive?.entries.filter {
          $0.scope == "source.jpeg"
        } ?? []
      let sourceMetadata = sourceCoding.segments.filter {
        (0xE0...0xEF).contains($0.marker) || $0.marker == 0xFE
      }
      check(
        archivedSegments.map(\.payload) == sourceMetadata.map { Data($0.payload) },
        "all source JPEG metadata segments are also available to the diagnostic report")
      let retainedCoding = try JPEGParser.parse(retained)
      check(
        retainedCoding.scanAndEOI == sourceCoding.scanAndEOI,
        "JPEG scan bytes remain unchanged for \(type)")
    }
  }

  await test("formatDescriptionOnlyFieldMarkersBlockCaptureAcceptance") {
    var fieldCount: Int32 = 2
    let count = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &fieldCount)!
    let sample = try compressedJPEGSample(
      jpegFixture(), fourCC: PixelFormatFourCC.mjpeg,
      formatExtensions: [kCMFormatDescriptionExtension_FieldCount: count])
    let frame = DeliveredFrame(
      sampleBuffer: sample, generation: 1, deviceUniqueID: "jpeg-field-fixture",
      fourCC: PixelFormatFourCC.mjpeg, width: 16, height: 16, timestampNanos: 1,
      hostMonotonicNanos: 1, hostWallClockISO: "2026-10-12T12:00:00Z")
    let metadata = FrameMetadataSnapshot(
      mediaTimeNanos: 1, wallClockAnchorISO: "2026-10-12T12:00:00Z", generation: 1)
    do {
      _ = try CapturedCapture(from: frame, metadata: metadata)
      recordFailure("format-description-only field marker entered the save pipeline")
    } catch let error as FrameExtraction.FieldMetadataError {
      check(error == .interlacedFieldCount(2), "format-description-only count is rejected")
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
    let makerNote = Array("VendorMakerNote".utf8) + [0x00, 0x01, 0xFE]
    check(
      exif.payload.suffix(makerNote.count).elementsEqual(makerNote), "fixture has MakerNote bytes")
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: sampleApplicationXMP())
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
