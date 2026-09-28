// JPEG preservation tests (segment byte-exactness through metadata-only
// insertion, malformed rejection) and lossless AVIF round-trip tests
// (native-channel exactness, AOM selection, speed zero).

import PixelBoothCore
import PixelBoothAdapters
import PixelBoothJPEG
import PixelBoothAVIF

// ---- JPEG fixtures ---------------------------------------------------------
/// Synthetic JPEG with SOI, APP0(JFIF), APP2(ICC chunk), APP1(Exif), APP1(XMP),
/// APP13(unknown vendor), DQT, SOF0, DHT, SOS + entropy payload, EOI.
func jpegFixture() -> [UInt8] {
  func seg(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [0xFF, marker,
     UInt8(((payload.count + 2) >> 8) & 0xFF), UInt8((payload.count + 2) & 0xFF)] + payload
  }
  var out: [UInt8] = [0xFF, 0xD8] // SOI
  out += seg(0xE0, Array("JFIF\0".utf8) + [0x01, 0x02, 0x00])
  out += seg(0xE2, Array("ICC_PROFILE\0".utf8) + [0, 1, 1] + [0x01, 0x02, 0x03, 0x04])
  out += seg(0xE1, Array("Exif\0\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A])
  out += seg(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8) + Array("<x:xmpmeta/>".utf8))
  out += seg(0xED, Array("UnknownVendorSegmentPayload0123456789".utf8))
  out += seg(0xDB, [0x00] + Array(repeating: 0x10, count: 64) + [0x01] + Array(repeating: 0x20, count: 64))
  out += seg(0xC0, [0x08, 0x00, 0x04, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00]) // 8-bit, 4x4, 1 comp
  out += seg(0xC4, [0x00] + Array(repeating: 0x00, count: 16) + [0x01, 0x12])
  out += [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]      // SOS
  out += Array(repeating: 0xA5, count: 256)                                 // entropy payload
  out += [0xFF, 0xD9]                                                       // EOI
  return out
}

func runJPEGSuite() {
  suite("JPEGPreservation")

  test("structureRoundTripsByteExact") {
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    check(parsed.reconstructedBytes() == original, "parse+rebuild must be byte-identical")
  }

  test("metadataInsertionPreservesImageCoding") {
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
      check(parsedAfter.segments.contains { $0.marker == seg.marker && $0.payload == seg.payload },
            "original segment 0x\(String(seg.marker, radix: 16)) preserved")
    }
    // New XMP present.
    check(parsedAfter.xmpSegment != nil, "additional XMP inserted")
  }

  test("unknownSegmentsSurvive") {
    let original = jpegFixture()
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(
      original: original, additionalXMP: Array("x".utf8))
    let parsedAfter = try! JPEGParser.parse(withMeta)
    let unknown = parsedAfter.unknownAPPSegments.filter { $0.marker == 0xED }
    check(unknown.count == 1, "unknown APP13 preserved through insertion")
  }

  test("truncatedJPEGRejected") {
    var truncated = jpegFixture()
    truncated.removeLast(8) // cut into scan data / EOI
    var thrown = false
    do { _ = try JPEGParser.parse(truncated) } catch { thrown = true }
    check(thrown, "truncated JPEG must be rejected")
  }

  test("malformedHeaderRejected") {
    var bogus = jpegFixture()
    bogus[0] = 0x00 // not SOI
    var thrown = false
    do { _ = try JPEGParser.parse(bogus) } catch { thrown = true }
    check(thrown, "non-SOI rejected")
  }

  test("makerNotePayloadPreservedVerbatim") {
    // Source Exif with a MakerNotes-looking TIFF payload must survive verbatim.
    let original = jpegFixture()
    let parsed = try! JPEGParser.parse(original)
    let exif = parsed.exifSegment!
    let withMeta = try! JPEGMetadataWriter.withAdditionalMetadata(original: original, additionalXMP: Array("z".utf8))
    let parsedAfter = try! JPEGParser.parse(withMeta)
    check(parsedAfter.exifSegment!.payload == exif.payload,
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

func runAVIFSuite() {
  suite("AVIFRoundTrip")

  test("rgbIdentityRoundTrip8Bit") {
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

  test("yuv420ExactNativeSamples") {
    let w = 16, h = 16
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
      planar, isRGBIdentity: false, yuvRange: .full, chromaLocation: .center)
    // Native-channel comparison (YUV planes, never RGB renderings).
    let decoded = try! LosslessAVIF.decode(encoded: encoded)
    check(decoded.width == w && decoded.height == h, "geometry preserved")
    check(decoded.planes[0] == yPlane, "Y plane exact")
    var eu = [UInt8](), ev = [UInt8]()
    for row in 0..<(h / 2) {
      for x in 0..<(w / 2) {
        eu.append(chroma[row * w + 2 * x])
        ev.append(chroma[row * w + 2 * x + 1])
      }
    }
    check(decoded.planes[1] == eu, "U plane exact")
    check(decoded.planes[2] == ev, "V plane exact")
  }

  test("superblackSuperwhitePreserved") {
    let w = 8, h = 2
    var yPlane = [UInt8](repeating: 0, count: w * h)
    var chroma = [UInt8](repeating: 128, count: (w / 2) * (h / 2) * 2)
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

  test("oddDimensionsLegalFor444") {
    let w = 7, h = 5
    let fixture = gradientFixture(w, h, bytesPerSample: 1)
    var data = fixture.data
    let planar = try! data.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptBGR24(
        data: raw.baseAddress!, bytesPerRow: fixture.rowBytes, width: w, height: h)
    }
    _ = try! LosslessAVIF.encodeLossless(
      planar, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil)
  }

  test("codecNeverAutoSubstituted") {
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
