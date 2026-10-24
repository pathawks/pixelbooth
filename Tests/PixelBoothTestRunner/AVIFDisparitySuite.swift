import Foundation
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothMetadata

func runAVIFDisparitySuite() async {
  suite("AVIFDisparity")

  await test("attachesRelativeFloatDisparityWithExactStoredSamplesAndUnchangedPrimary") {
    let primary = try disparityPrimaryFixture(alpha: true)
    let values: [Float] = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32]
    let result = try AVIFDisparity.attach(
      to: primary, width: 5, height: 3, relativeDisparity: values,
      modelIdentifier: "synthetic-test <model> & \"revision\"",
      preprocessingDescription: "full field > RGB & scale", outputDescription: "test floats")
    let extracted = try AVIFDisparity.extract(from: result.data)
    let expected = values.map { UInt8(((Double($0) - 2) / 30 * 255).rounded()) }
    check(extracted.width == 5 && extracted.height == 3, "odd auxiliary dimensions preserved")
    check(extracted.samples == expected, "every quantized native sample decodes exactly")
    check(
      try LosslessAVIF.decode(encoded: primary) == LosslessAVIF.decode(encoded: result.data),
      "all primary channels including alpha remain identical")
    check(result.descriptor.minimumRelativeDisparity == 2, "minimum model value retained")
    check(result.descriptor.maximumRelativeDisparity == 32, "maximum model value retained")
    check(result.descriptor.renderingScale == nil, "no render normalization without an intent")
    check(
      result.descriptor.nativeMinimumDisparity == 2
        && result.descriptor.nativeMaximumDisparity == 32,
      "unrequested render normalization cannot replace the native source range")
    check(result.descriptor.losslessStorageVerified, "stored quantized samples verified")
    check(
      extracted.xmp.contains("apdi:NativeFormat=\"1717856627\""),
      "native fdis format uses Apple's numeric FourCC serialization")
    check(
      extracted.xmp.contains("apdi:StoredFormat=\"1278226488\""),
      "stored L008 format uses Apple's numeric FourCC serialization")
    check(
      extracted.xmp.contains("apdi:FloatMinValue=\"2.0\"")
        && extracted.xmp.contains("apdi:FloatMaxValue=\"32.0\"")
        && extracted.xmp.contains("apdi:IntMinValue=\"0\"")
        && extracted.xmp.contains("apdi:IntMaxValue=\"255\""),
      "Apple pixel data metadata describes the actual integer-to-float reconstruction")
    check(
      extracted.xmp.contains("depthData:Accuracy=\"relative\""), "uncalibrated accuracy recorded")
    check(
      extracted.xmp.contains("&lt;model&gt; &amp; &quot;revision&quot;"), "model text XML escaped")
    check(extracted.xmp.contains("full field &gt; RGB &amp; scale"), "preprocessing XML escaped")
    check(!extracted.xmp.contains("SimulatedAperture"), "no fabricated portrait recipe")
    check(!extracted.xmp.contains("pbdepth:RenderScale="), "raw map has no virtual render scale")
    check(!extracted.xmp.contains("Filtered="), "no invented filtering observation")
    let finalMedia = try disparityMediaPayload(result.data)
    for originalPayload in try disparityItemPayloads(primary) {
      check(
        finalMedia.windows(ofCount: originalPayload.count).contains {
          $0.elementsEqual(originalPayload)
        }, "each original AV1 and XMP payload survives byte-for-byte")
    }
    check(
      result.data.windows(ofCount: AVIFDisparity.auxiliaryType.utf8.count).contains {
        $0.elementsEqual(AVIFDisparity.auxiliaryType.utf8)
      }, "normative AVIF depth auxiliary type included")
  }

  await test("randomMapQuantizationRoundTripsEveryStoredSample") {
    let primary = try disparityPrimaryFixture(alpha: false)
    var state: UInt64 = 0x4573_4F72_18AE_2D50
    var values: [Float] = [0, 1]
    for _ in 2..<(17 * 13) {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      values.append(Float((state >> 32) & 65_535) / 65_535)
    }
    let result = try AVIFDisparity.attach(
      to: primary, width: 17, height: 13, relativeDisparity: values,
      modelIdentifier: "synthetic-test")
    let map = try AVIFDisparity.extract(from: result.data)
    check(
      map.samples == values.map { UInt8((Double($0) * 255).rounded()) },
      "all odd-dimension pseudorandom stored samples are exact")
  }

  await test("applicationRenderIntentAddsApertureWithoutInventingCameraMetadata") {
    let primary = try disparityPrimaryFixture(alpha: true)
    let intent = try PortraitRenderIntent(primaryWidth: 8, primaryHeight: 6)
    let result = try AVIFDisparity.attach(
      to: primary, width: 2, height: 2, relativeDisparity: [0, 0.25, 0.5, 1],
      modelIdentifier: "synthetic-test", portraitRenderIntent: intent)
    let extracted = try AVIFDisparity.extract(from: result.data)
    check(
      result.descriptor.portraitRenderIntent == intent, "render defaults retained in descriptor")
    check(
      extracted.xmp.contains("depthBlurEffect:SimulatedAperture=\"2.8\""),
      "application-selected aperture attached to depth item")
    check(
      extracted.xmp.contains("pbdepth:PortraitRenderIntentOrigin=\"application-default\""),
      "aperture origin distinguished from camera optics")
    for absent in ["RenderingParameters", "IntrinsicMatrix", "Quality=", "Filtered=", "FNumber"] {
      check(!extracted.xmp.contains(absent), "no unestablished \(absent) declaration")
    }
    check(
      try LosslessAVIF.decode(encoded: result.data) == LosslessAVIF.decode(encoded: primary),
      "render metadata preserves all primary channels including alpha")
    expectThrows(
      {
        try AVIFDisparity.attach(
          to: primary, width: 2, height: 2, relativeDisparity: [0, 0.25, 0.5, 1],
          modelIdentifier: "synthetic-test",
          portraitRenderIntent: PortraitRenderIntent(primaryWidth: 6, primaryHeight: 8))
      }, "focus geometry must describe the primary, not the model or mirrored preview")
  }

  await test("portraitRenderScaleIsIndependentOfArbitraryModelGainAndOffset") {
    let primary = try disparityPrimaryFixture(alpha: true)
    let before = try LosslessAVIF.decode(encoded: primary)
    let intent = try PortraitRenderIntent(primaryWidth: 8, primaryHeight: 6)
    let maps: [[Float]] = [[0, 0.25, 0.5, 1], [64, 128, 192, 320]]
    var storedMaps: [[UInt8]] = []
    for values in maps {
      let attached = try AVIFDisparity.attach(
        to: primary, width: 2, height: 2, relativeDisparity: values,
        modelIdentifier: "synthetic-affine-test", portraitRenderIntent: intent)
      let descriptor = attached.descriptor
      let stored = try AVIFDisparity.extract(from: attached.data)
      storedMaps.append(stored.samples)
      check(stored.samples == [0, 64, 128, 255], "arbitrary model scale leaves prepared q exact")
      check(
        descriptor.minimumRelativeDisparity == values.min()
          && descriptor.maximumRelativeDisparity == values.max(),
        "actual raw model endpoints retained separately from the render scale")
      check(descriptor.renderingScale == .portraitRelativeV1, "versioned render scale recorded")
      check(
        descriptor.nativeMinimumDisparity == Float(1.777344)
          && descriptor.nativeMaximumDisparity == Float(6.09375),
        "native readback uses the selected fixed virtual range")
      check(
        stored.xmp.contains("apdi:FloatMinValue=\"\(descriptor.nativeMinimumDisparity)\"")
          && stored.xmp.contains("apdi:FloatMaxValue=\"\(descriptor.nativeMaximumDisparity)\""),
        "Apple reconstruction declares the virtual native endpoints")
      check(
        stored.xmp.contains("pbdepth:Minimum=\"\(values.min()!)\"")
          && stored.xmp.contains("pbdepth:Maximum=\"\(values.max()!)\""),
        "source model endpoints remain available in application provenance")
      for expected in [
        "pbdepth:SchemaVersion=\"2\"",
        "pbdepth:RenderScale=\"portrait-relative-v1\"",
        "pbdepth:RenderScaleUnits=\"virtual-relative-disparity\"",
        "pbdepth:RenderMinimum=\"\(descriptor.nativeMinimumDisparity)\"",
        "pbdepth:RenderMaximum=\"\(descriptor.nativeMaximumDisparity)\"",
        "pbdepth:RenderReconstruction=\"renderMinimum+sample*(renderMaximum-renderMinimum)/255\"",
        "pbdepth:SourceRangeRole=\"model-output-before-render-normalization\"",
      ] {
        check(stored.xmp.contains(expected), "explicit render provenance: \(expected)")
      }
      for absent in ["RenderingParameters", "IntrinsicMatrix", "Quality=", "Filtered=", "FNumber"] {
        check(!stored.xmp.contains(absent), "render scaling does not invent \(absent)")
      }
      check(
        try LosslessAVIF.decode(encoded: attached.data) == before,
        "render normalization preserves every primary native channel and descriptor")
      check(
        try JSONDecoder().decode(
          AVIFDisparity.Descriptor.self, from: JSONEncoder().encode(descriptor)) == descriptor,
        "versioned rendering selection survives descriptor persistence")
    }
    check(storedMaps[0] == storedMaps[1], "affine-equivalent model maps store identical q planes")
  }

  await test("constantPortraitMapDoesNotInventDisparityContrast") {
    let primary = try disparityPrimaryFixture(alpha: false)
    let intent = try PortraitRenderIntent(primaryWidth: 8, primaryHeight: 6)
    let attached = try AVIFDisparity.attach(
      to: primary, width: 2, height: 2, relativeDisparity: [7, 7, 7, 7],
      modelIdentifier: "synthetic-constant-test", portraitRenderIntent: intent)
    let stored = try AVIFDisparity.extract(from: attached.data)
    check(stored.samples == [0, 0, 0, 0], "constant source remains constant after render mapping")
    check(
      attached.descriptor.minimumRelativeDisparity == 7
        && attached.descriptor.maximumRelativeDisparity == 7,
      "constant source endpoints remain exact")
    check(
      attached.descriptor.renderingScale == .portraitRelativeV1
        && attached.descriptor.nativeMinimumDisparity == Float(1.777344),
      "constant q plane reconstructs at one documented native level")
  }

  await test("legacyDescriptorWithoutRenderingScaleRetainsItsOriginalNativeRange") {
    let primary = try disparityPrimaryFixture(alpha: false)
    let intent = try PortraitRenderIntent(primaryWidth: 8, primaryHeight: 6)
    let attached = try AVIFDisparity.attach(
      to: primary, width: 2, height: 2, relativeDisparity: [64, 128, 192, 320],
      modelIdentifier: "synthetic-legacy-test", portraitRenderIntent: intent)
    let encoded = try JSONEncoder().encode(attached.descriptor)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw AVIFDisparity.DisparityError.invalidMap("descriptor JSON fixture")
    }
    object.removeValue(forKey: "renderingScale")
    let legacy = try JSONDecoder().decode(
      AVIFDisparity.Descriptor.self,
      from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    check(legacy.renderingScale == nil, "missing legacy field does not select a new render scale")
    check(legacy.portraitRenderIntent == intent, "legacy render intent remains recoverable")
    check(
      legacy.nativeMinimumDisparity == 64 && legacy.nativeMaximumDisparity == 320,
      "older captures retain the native endpoints used when their file was generated")
  }

  await test("constantAndExtremeFloatMapsHaveDocumentedQuantization") {
    let primary = try disparityPrimaryFixture(alpha: false)
    for values: [Float] in [[7, 7, 7, 7], [0, .greatestFiniteMagnitude, 1, 100]] {
      let result = try AVIFDisparity.attach(
        to: primary, width: 2, height: 2, relativeDisparity: values,
        modelIdentifier: "synthetic-test")
      let extracted = try AVIFDisparity.extract(from: result.data)
      check(extracted.samples[0] == 0, "minimum maps to zero without a Float overflow")
      if values[0] == values[1] {
        check(extracted.samples == [0, 0, 0, 0], "constant map reconstructs from recorded minimum")
        check(result.descriptor.minimumRelativeDisparity == 7, "constant scale retained")
      } else {
        check(extracted.samples[1] == 255, "largest finite Float maps to maximum")
      }
    }
  }

  await test("highBitDepthLimitedRangePrimaryRetainsStorageExtremesAndColorDescriptors") {
    for (depth, width, height, chromaWidth, chromaHeight) in [(10, 8, 6, 4, 3), (12, 7, 5, 7, 5)] {
      let planes: [[UInt8]] = (0..<3).map { channel in
        let count = channel == 0 ? width * height : chromaWidth * chromaHeight
        return (0..<count).flatMap { index -> [UInt8] in
          let maximum = (1 << depth) - 1
          let values = [0, 1, 255, 256, maximum - 1, maximum]
          let value = values[(index + channel) % values.count]
          return [UInt8(value & 255), UInt8(value >> 8)]
        }
      }
      let primary = try planes[0].withUnsafeBytes { y in
        try planes[1].withUnsafeBytes { u in
          try planes[2].withUnsafeBytes { v in
            let image = PlanarImage(
              width: width, height: height, bitsPerChannel: depth,
              planes: [y.baseAddress!, u.baseAddress!, v.baseAddress!],
              bytesPerRow: [width * 2, chromaWidth * 2, chromaWidth * 2],
              rowCount: [height, chromaHeight, chromaHeight], bytesPerSample: 2,
              chromaWidth: chromaWidth, chromaHeight: chromaHeight)
            return try LosslessAVIF.encodeLossless(
              image, isRGBIdentity: false, yuvRange: .limited, chromaLocation: nil,
              colorPrimaries: 9, transferCharacteristics: 16, matrixCoefficients: 9
            ).data
          }
        }
      }
      let result = try AVIFDisparity.attach(
        to: primary, width: 3, height: 2, relativeDisparity: [0, 0.25, 0.5, 0.75, 0.9, 1],
        modelIdentifier: "synthetic-test")
      let decoded = try LosslessAVIF.decode(encoded: result.data)
      check(
        decoded.planes == planes, "superblack/superwhite \(depth)-bit storage samples stay exact")
      check(
        decoded.depth == depth && decoded.range == 0, "primary depth and limited range stay exact")
      check(
        decoded.colorPrimaries == 9 && decoded.transferCharacteristics == 16
          && decoded.matrixCoefficients == 9,
        "primary HDR/color descriptors stay exact")
      check(
        try decoded == LosslessAVIF.decode(encoded: primary),
        "all original primary native channels and descriptors stay equal")
    }
  }

  await test("invalidMapsAndDuplicateAuxiliariesAreRefused") {
    let primary = try disparityPrimaryFixture(alpha: false)
    for values: [Float] in [[.nan], [.infinity], [-1]] {
      expectThrows(
        {
          try AVIFDisparity.attach(
            to: primary, width: 1, height: 1, relativeDisparity: values,
            modelIdentifier: "synthetic-test")
        }, "nonfinite and negative disparity refused")
    }
    expectThrows(
      {
        try AVIFDisparity.attach(
          to: primary, width: Int.max, height: 2, relativeDisparity: [],
          modelIdentifier: "synthetic-test")
      }, "overflowing geometry refused")
    expectThrows(
      {
        try AVIFDisparity.attach(
          to: primary, width: 2, height: 2, relativeDisparity: [1],
          modelIdentifier: "synthetic-test")
      }, "sample count mismatch refused")
    let first = try AVIFDisparity.attach(
      to: primary, width: 1, height: 1, relativeDisparity: [1], modelIdentifier: "synthetic-test")
    expectThrows(
      {
        try AVIFDisparity.attach(
          to: first.data, width: 1, height: 1, relativeDisparity: [1],
          modelIdentifier: "synthetic-test")
      }, "a second disparity map cannot silently replace the existing map")
  }

  await test("malformedContainersFailWithoutOutOfBoundsAccess") {
    let primary = try disparityPrimaryFixture(alpha: false)
    let result = try AVIFDisparity.attach(
      to: primary, width: 3, height: 1, relativeDisparity: [0, 0.5, 1],
      modelIdentifier: "synthetic-test")
    for length in [0, 1, 7, 8, 16, result.data.count - 1] {
      expectThrows(
        { try AVIFDisparity.extract(from: Array(result.data.prefix(length))) },
        "truncated container rejected at \(length)")
    }
    var unbounded = result.data
    unbounded.replaceSubrange(0..<4, with: [0, 0, 0, 0])
    expectThrows({ try AVIFDisparity.extract(from: unbounded) }, "unbounded box rejected")
    var extent = result.data
    let iloc = try disparityFindBox("iloc", in: extent)
    // Version 0, 32-bit offset/length, one extent: first extent offset follows
    // full-box header, size fields, count, ID, data_reference_index, extent_count.
    extent.replaceSubrange((iloc + 22)..<(iloc + 26), with: [255, 255, 255, 255])
    expectThrows({ try AVIFDisparity.extract(from: extent) }, "out-of-file extent rejected")
    var association = result.data
    let ipma = try disparityFindBox("ipma", in: association)
    association.replaceSubrange((ipma + 19)..<(ipma + 21), with: [255, 255])
    expectThrows(
      { try AVIFDisparity.extract(from: association) }, "invalid property index rejected")
    expectThrows({ try AVIFDisparity.extract(from: primary) }, "missing auxiliary rejected")
    do {
      _ = try AVIFDisparity.extract(from: disparityAmplifiedExtentFixture())
      recordFailure("aliased extent amplification accepted")
    } catch let error as AVIFDisparity.DisparityError {
      check(
        error == .invalidContainer("item extent exceeds media data"),
        "repeated in-bounds extents cannot amplify materialized storage beyond the file size")
    }
  }
}

private func disparityPrimaryFixture(alpha: Bool) throws -> [UInt8] {
  let width = 8
  let height = 6
  var bytes: [UInt8] = (0..<(width * height * (alpha ? 4 : 3))).map { UInt8(($0 * 83) % 256) }
  let image = try bytes.withUnsafeMutableBytes { raw in
    if alpha {
      return try SampleLayoutAdapter.adaptBGRA32(
        data: raw.baseAddress!, bytesPerRow: width * 4, width: width, height: height)
    }
    return try SampleLayoutAdapter.adaptBGR24(
      data: raw.baseAddress!, bytesPerRow: width * 3, width: width, height: height)
  }
  defer { for pointer in image.ownedStorage { pointer?.deallocate() } }
  return try LosslessAVIF.encodeLossless(
    image, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil,
    xmpPayload: Array("<camera:unknown xmlns:camera='urn:test'>unchanged</camera:unknown>".utf8)
  ).data
}

private func disparityAmplifiedExtentFixture() -> [UInt8] {
  func integer(_ value: Int) -> [UInt8] {
    [
      UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
      UInt8((value >> 8) & 255), UInt8(value & 255),
    ]
  }
  func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    integer(payload.count + 8) + Array(type.utf8) + payload
  }
  let fileType = box("ftyp", Array("avif".utf8) + [0, 0, 0, 0] + Array("avif".utf8))
  let primary = box("pitm", [0, 0, 0, 0, 0, 1])
  let info = box(
    "iinf",
    [0, 0, 0, 0, 0, 1]
      + box("infe", [2, 0, 0, 0, 0, 1, 0, 0] + Array("av01".utf8) + [0]))
  func meta(offset: Int) -> [UInt8] {
    let location = box(
      "iloc",
      [0, 0, 0, 0, 0x44, 0, 0, 1, 0, 1, 0, 0, 0, 2]
        + integer(offset) + integer(4_096) + integer(offset) + integer(4_096))
    return box("meta", [0, 0, 0, 0] + primary + info + location)
  }
  let offset = fileType.count + meta(offset: 0).count + 8
  return fileType + meta(offset: offset) + box("mdat", [UInt8](repeating: 1, count: 4_096))
}

private func disparityFindBox(_ type: String, in bytes: [UInt8]) throws -> Int {
  let signature = Array(type.utf8)
  guard bytes.count >= 8 else {
    throw AVIFDisparity.DisparityError.invalidContainer("test fixture")
  }
  for offset in 4...(bytes.count - 4) {
    if bytes[offset..<(offset + 4)].elementsEqual(signature) { return offset - 4 }
  }
  throw AVIFDisparity.DisparityError.invalidContainer("test box not found")
}

private func disparityMediaPayload(_ bytes: [UInt8]) throws -> [UInt8] {
  let start = try disparityFindBox("mdat", in: bytes)
  return Array(bytes[(start + 8)...])
}

private func disparityItemPayloads(_ bytes: [UInt8]) throws -> [[UInt8]] {
  let start = try disparityFindBox("iloc", in: bytes)
  func integer(_ offset: Int, count: Int) -> Int {
    bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
  }
  let itemCount = integer(start + 14, count: 2)
  var position = start + 16
  var payloads: [[UInt8]] = []
  for _ in 0..<itemCount {
    let extentCount = integer(position + 4, count: 2)
    position += 6
    var item: [UInt8] = []
    for _ in 0..<extentCount {
      let offset = integer(position, count: 4)
      let count = integer(position + 4, count: 4)
      item += bytes[offset..<(offset + count)]
      position += 8
    }
    payloads.append(item)
  }
  return payloads
}

extension Array where Element == UInt8 {
  fileprivate func windows(ofCount count: Int) -> [ArraySlice<UInt8>] {
    guard count > 0, self.count >= count else { return [] }
    return (0...(self.count - count)).map { self[$0..<($0 + count)] }
  }
}
