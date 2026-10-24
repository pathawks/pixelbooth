import AVFoundation
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothDepth
import PixelBoothMetadata

func runDepthSuite() async {
  suite("DepthAnythingV2")

  await test("relativeMapPreservesModelValues") {
    let values: [Float] = [0, Float(Float16.leastNonzeroMagnitude), 0.5, 1]
    let map = try RelativeDisparityMap(width: 2, height: 2, values: values)
    check(map.width == 2 && map.height == 2, "map geometry retained")
    check(map.values == values, "no inversion, clamp, or normalization of model samples")
  }

  await test("invalidRelativeMapsRejected") {
    for values: [Float] in [[.nan], [.infinity], [-0.01], [1.01]] {
      expectThrows(
        { try RelativeDisparityMap(width: 1, height: 1, values: values) },
        "invalid model values rejected")
    }
    expectThrows(
      { try RelativeDisparityMap(width: 0, height: 1, values: []) }, "empty geometry")
    expectThrows(
      { try RelativeDisparityMap(width: 2, height: 2, values: [0]) }, "sample count")
    expectThrows(
      { try RelativeDisparityMap(width: Int.max, height: 2, values: []) }, "overflow")
    expectThrows(
      { try RelativeDisparityMap(width: 4_194_305, height: 1, values: []) }, "memory bound")
  }

  await test("invalidEncodedImageRejected") {
    let estimator = DepthAnythingV2Estimator(configuration: .smallF16)
    do {
      _ = try await estimator.estimate(avifData: [0, 1, 2, 3])
      recordFailure("malformed AVIF accepted")
    } catch DepthEstimationError.invalidImage {
      // The input fails independently of model availability.
    }
  }

  await test("configurationJSONAndBoundsAreValidated") {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelBooth-depth-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("DepthModel.json")
    let encoded = try JSONEncoder().encode(DepthModelConfiguration.smallF16)
    try encoded.write(to: path)
    check(
      try DepthModelConfiguration.load(from: path) == .smallF16,
      "complete descriptor preserves source identity and model contract")
    var fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    fields["schemaVersion"] = 2
    try JSONSerialization.data(withJSONObject: fields).write(to: path)
    expectThrows({ try DepthModelConfiguration.load(from: path) }, "unknown descriptor schema")
    fields["schemaVersion"] = 1
    fields["outputWidth"] = 4_096
    fields["outputHeight"] = 4_096
    try JSONSerialization.data(withJSONObject: fields).write(to: path)
    expectThrows({ try DepthModelConfiguration.load(from: path) }, "output memory limit")
    fields["outputWidth"] = 518
    fields["outputHeight"] = 392
    fields["modelResourceName"] = "../OtherModel"
    try JSONSerialization.data(withJSONObject: fields).write(to: path)
    expectThrows(
      { try DepthModelConfiguration.load(from: path) }, "resource path is not configurable")
    try Data(repeating: 0, count: 65_537).write(to: path)
    expectThrows({ try DepthModelConfiguration.load(from: path) }, "descriptor byte limit")
  }

  await test("missingConfigurationDoesNotSelectSmall") {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelBooth-missing-config-\(UUID().uuidString).json")
    let estimator = DepthAnythingV2Estimator(configurationURL: missing)
    do {
      _ = try await estimator.estimate(avifData: try depthInferenceFixture())
      recordFailure("missing descriptor silently selected a model")
    } catch DepthEstimationError.modelUnavailable {
      // The default build selection is mandatory, even when an old Small model exists.
    }
  }

  await test("rawAndNormalizedOutputsRetainTheirDeclaredMeaning") {
    let raw = try outputFixtureConfiguration(.multiArrayFloat16)
    let values: [Float] = [0, 2, 4, 6, 8, 10]
    let map = try RelativeDisparityMap(width: 3, height: 2, values: values, configuration: raw)
    check(
      map.values == values && map.configuration == raw, "raw values and actual provenance retained")
    check(
      map.modelIdentifier.contains("sourceModelSHA256=\(raw.sourceModelSHA256)")
        && map.modelIdentifier.contains("sourceWeightsSHA256=\(raw.sourceWeightsSHA256)"),
      "friendly model identifiers cannot omit source pins")
    let normalized = try outputFixtureConfiguration(.multiArrayFloat16, normalized: true)
    expectThrows(
      { try RelativeDisparityMap(width: 3, height: 2, values: values, configuration: normalized) },
      "normalized contracts reject values above one")
    expectThrows(
      { try RelativeDisparityMap(width: 2, height: 3, values: values, configuration: raw) },
      "map provenance cannot label different output geometry")
  }

  await test("stridedFloatArraysCopyEveryMeaningfulSample") {
    for representation in [
      DepthModelConfiguration.OutputRepresentation.multiArrayFloat16, .multiArrayFloat32,
    ] {
      let configuration = try outputFixtureConfiguration(representation)
      let halfFloat = representation == .multiArrayFloat16
      let array = MLMultiArray(
        shape: [1, 2, 3], dataType: halfFloat ? .float16 : .float32, strides: [20, 7, 2])
      let expected: [Float] = [0, 2, 4, 6, 8, 10]
      array.withUnsafeMutableBytes { bytes, strides in
        for index in bytes.indices { bytes[index] = 0xFF }
        for y in 0..<2 {
          for x in 0..<3 {
            let sample = y * strides[1] + x * strides[2]
            if halfFloat {
              bytes.storeBytes(
                of: Float16(expected[y * 3 + x]).bitPattern,
                toByteOffset: sample * 2, as: UInt16.self)
            } else {
              bytes.storeBytes(of: expected[y * 3 + x], toByteOffset: sample * 4, as: Float.self)
            }
          }
        }
      }
      let map = try DepthAnythingV2Estimator.relativeDisparity(
        from: MLFeatureValue(multiArray: array), configuration: configuration)
      check(map.values == expected, "\(representation): padding omitted and raw values retained")
      check(map.configuration == configuration, "\(representation): selected identity carried")
      let wrongShape = try MLMultiArray(
        shape: [1, 3, 2], dataType: halfFloat ? .float16 : .float32)
      expectThrows(
        {
          try DepthAnythingV2Estimator.relativeDisparity(
            from: MLFeatureValue(multiArray: wrongShape), configuration: configuration)
        }, "array axes never inferred or transposed")
    }
  }

  await test("derivedInferenceInputRetainsFullFieldAndRowOrder") {
    let sourceWidth = 12
    let sourceHeight = 20
    var rgb = [UInt8]()
    for y in 0..<sourceHeight {
      for x in 0..<sourceWidth {
        let color: [UInt8]
        if y == 0 {
          color = [255, 0, 255]
        } else if y == sourceHeight - 1 {
          color = [0, 255, 255]
        } else if x == 0 {
          color = [255, 128, 0]
        } else if x == sourceWidth - 1 {
          color = [128, 0, 255]
        } else if y < sourceHeight / 2 {
          color = x < sourceWidth / 2 ? [255, 0, 0] : [0, 255, 0]
        } else {
          color = x < sourceWidth / 2 ? [0, 0, 255] : [255, 255, 0]
        }
        rgb.append(contentsOf: color)
      }
    }
    let source = try encodeDepthRGBFixture(rgb, width: sourceWidth, height: sourceHeight)
    let input = try DepthAnythingV2Estimator.makeInferenceInput(avifData: source)
    check(input.width == 518 && input.height == 392, "fixed model input geometry")
    check(input.bgraPixels.count == 518 * 392 * 4, "bounded packed input storage")
    let positions = [
      (129, 98, [UInt8](arrayLiteral: 0, 0, 255)),
      (388, 98, [UInt8](arrayLiteral: 0, 255, 0)),
      (129, 294, [UInt8](arrayLiteral: 255, 0, 0)),
      (388, 294, [UInt8](arrayLiteral: 0, 255, 255)),
      (259, 2, [UInt8](arrayLiteral: 255, 0, 255)),
      (259, 389, [UInt8](arrayLiteral: 255, 255, 0)),
      (2, 196, [UInt8](arrayLiteral: 0, 128, 255)),
      (515, 196, [UInt8](arrayLiteral: 255, 0, 128)),
    ]
    for (x, y, expected) in positions {
      let offset = (y * input.width + x) * 4
      let actual = Array(input.bgraPixels[offset..<(offset + 3)])
      check(
        zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
        "source color/field retained at \(x),\(y): \(actual) expected \(expected)")
    }
  }

  await test("chosenRenderIntentUsesTopLeftFocusCoordinates") {
    let intent = try PortraitRenderIntent(
      primaryWidth: 24, primaryHeight: 40, simulatedAperture: 5.6,
      focusCenterX: 0.2, focusCenterY: 0.8, focusWidth: 0.2, focusHeight: 0.1,
      origin: .applicationChosen)
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      appVersion: "test", captureBackend: "synthetic-fixture", backendVersion: "test",
      libavifVersion: LosslessAVIF.libraryVersion, actualCaptureFormat: "RGB8 24x40",
      encoderSettings: "lossless", metadataProvenance: [], fidelity: "synthetic-test",
      hostLocation: nil, mediaTimeNanos: 1, wallClockAnchorISO: "2026-10-22T00:00:00Z",
      portraitRenderIntent: intent)
    let primary = try depthInferenceFixture(xmp: xmp)
    let attached = try AVIFDisparity.attach(
      to: primary, width: 2, height: 2, relativeDisparity: [0, 0.25, 0.5, 1],
      modelIdentifier: "synthetic-chosen-render-intent", portraitRenderIntent: intent)
    let context = CIContext(options: [.cacheIntermediates: false])
    guard
      let filter = context.depthBlurEffectFilter(forImageData: Data(attached.data), options: nil),
      let aperture = filter.value(forKey: "inputAperture") as? NSNumber,
      let focus = filter.value(forKey: "inputFocusRect") as? CIVector, focus.count == 4
    else {
      throw DepthEstimationError.invalidMap("public depth-blur factory cannot read chosen intent")
    }
    check(
      abs(aperture.doubleValue - 5.6) <= 0.000_001, "factory consumes chosen simulated aperture")
    check(
      abs(focus.x - 0.1) <= 0.000_001 && abs(focus.y - 0.15) <= 0.000_001
        && abs(focus.z - 0.2) <= 0.000_001 && abs(focus.w - 0.1) <= 0.000_001,
      "factory converts top-left MWG focus into bottom-left rendering coordinates")
  }

  await test("virtualPortraitRangeReconstructsNativeFdisFromExactStoredSamples") {
    let primary = try depthInferenceFixture()
    let intent = try PortraitRenderIntent(primaryWidth: 24, primaryHeight: 40)
    let attached = try AVIFDisparity.attach(
      to: primary, width: 2, height: 2, relativeDisparity: [64, 128, 192, 320],
      modelIdentifier: "synthetic-native-render-scale", portraitRenderIntent: intent)
    let stored = try AVIFDisparity.extract(from: attached.data)
    check(stored.samples == [0, 64, 128, 255], "all original prepared gray8 samples remain exact")
    guard let source = CGImageSourceCreateWithData(Data(attached.data) as CFData, nil),
      let copied = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, CGImageSourceGetPrimaryImageIndex(source), kCGImageAuxiliaryDataTypeDisparity)
        as? [AnyHashable: Any]
    else { throw DepthEstimationError.invalidMap("ImageIO did not expose virtual disparity") }
    let depth = try AVDepthData(fromDictionaryRepresentation: copied)
    check(
      depth.depthDataType == kCVPixelFormatType_DisparityFloat32, "native fdis without conversion")
    check(depth.depthDataAccuracy == .relative, "virtual render mapping retains relative accuracy")
    check(!depth.isDepthDataFiltered, "normalization does not invent filtering")
    check(depth.cameraCalibrationData == nil, "normalization does not invent camera calibration")
    let map = depth.depthDataMap
    check(
      CVPixelBufferGetWidth(map) == 2 && CVPixelBufferGetHeight(map) == 2,
      "native readback retains stored geometry")
    guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else {
      throw DepthEstimationError.invalidMap("cannot lock virtual disparity")
    }
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(map)
    guard let base = CVPixelBufferGetBaseAddress(map), stride >= 8,
      stride <= Int.max / 2, stride * 2 <= CVPixelBufferGetDataSize(map)
    else { throw DepthEstimationError.invalidMap("invalid virtual disparity storage") }
    let minimum = Double(attached.descriptor.nativeMinimumDisparity)
    let maximum = Double(attached.descriptor.nativeMaximumDisparity)
    check(
      minimum == Double(Float(1.777344)) && maximum == Double(Float(6.09375)),
      "documented virtual range replaces arbitrary raw model gain and offset")
    var maximumULPError: Float = 0
    for index in stored.samples.indices {
      let actual = base.loadUnaligned(
        fromByteOffset: (index / 2) * stride + (index % 2) * 4, as: Float.self)
      guard actual.isFinite else { throw DepthEstimationError.invalidMap("nonfinite virtual fdis") }
      let expected = Float(minimum + Double(stored.samples[index]) * (maximum - minimum) / 255)
      maximumULPError = max(maximumULPError, abs(actual - expected) / expected.ulp)
    }
    check(maximumULPError <= 4, "every native sample matches the documented virtual reconstruction")
    check(
      try LosslessAVIF.decode(encoded: attached.data) == LosslessAVIF.decode(encoded: primary),
      "native primary preserved alongside the render-only scale")
  }

  await test("requestedMissingModelFails") {
    let bytes = try depthInferenceFixture()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixelBooth-missing-depth-\(UUID().uuidString).mlmodelc")
    let estimator = DepthAnythingV2Estimator(configuration: .smallF16, modelURL: missing)
    do {
      _ = try await estimator.estimate(avifData: bytes)
      recordFailure("requested disparity silently succeeded without its model")
    } catch DepthEstimationError.modelUnavailable {
      // Required model errors propagate so the staged capture remains recoverable.
    }
  }

  await test("pinnedCoreMLModelInfersSyntheticAVIF") {
    guard let modelPath = ProcessInfo.processInfo.environment["PIXELBOOTH_DEPTH_MODEL"],
      let configurationPath = ProcessInfo.processInfo.environment["PIXELBOOTH_DEPTH_CONFIGURATION"]
    else {
      try skipTest(
        "model/configuration paths not set; selected inference is explicitly enabled by validate.sh"
      )
    }
    let modelURL = URL(fileURLWithPath: modelPath)
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw DepthEstimationError.modelUnavailable
    }
    let intent = try PortraitRenderIntent(primaryWidth: 24, primaryHeight: 40)
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      appVersion: "test", captureBackend: "synthetic-fixture", backendVersion: "test",
      libavifVersion: LosslessAVIF.libraryVersion, actualCaptureFormat: "RGB8 24x40",
      encoderSettings: "lossless", metadataProvenance: [], fidelity: "synthetic-test",
      hostLocation: nil, mediaTimeNanos: 1, wallClockAnchorISO: "2026-10-22T00:00:00Z",
      portraitRenderIntent: intent)
    let bytes = try depthInferenceFixture(xmp: xmp)
    let before = try LosslessAVIF.decode(encoded: bytes)
    let configuration = try DepthModelConfiguration.load(
      from: URL(fileURLWithPath: configurationPath))
    let estimator = DepthAnythingV2Estimator(configuration: configuration, modelURL: modelURL)
    let map = try await estimator.estimate(avifData: bytes)
    check(
      map.width == configuration.outputWidth && map.height == configuration.outputHeight,
      "verified selected output geometry")
    check(map.values.count == map.width * map.height, "all model output samples copied")
    check(
      map.values.allSatisfy {
        $0.isFinite && $0 >= 0 && (!configuration.outputNormalizedByMaximum || $0 <= 1)
      }, "finite samples follow declared model normalization")
    check(map.configuration == configuration, "actual selected model provenance retained")
    check((map.values.max() ?? 0) > (map.values.min() ?? 0), "model produces nonconstant estimates")
    let after = try LosslessAVIF.decode(encoded: bytes)
    check(before.planes == after.planes, "derived RGB inference does not change primary samples")
    check(before.width == 24 && before.height == 40, "portrait primary retains its sample geometry")

    let attached = try AVIFDisparity.attach(
      to: bytes, width: map.width, height: map.height, relativeDisparity: map.values,
      modelIdentifier: map.modelIdentifier,
      preprocessingDescription: map.preprocessingDescription,
      outputDescription: map.outputDescription, portraitRenderIntent: intent)
    let stored = try AVIFDisparity.extract(from: attached.data)
    let minimum = Double(map.values.min()!)
    let maximum = Double(map.values.max()!)
    let nativeMinimum = Double(attached.descriptor.nativeMinimumDisparity)
    let nativeMaximum = Double(attached.descriptor.nativeMaximumDisparity)
    check(
      attached.descriptor.minimumRelativeDisparity == map.values.min()
        && attached.descriptor.maximumRelativeDisparity == map.values.max(),
      "actual selected model endpoints remain separate from the virtual render endpoints")
    check(
      attached.descriptor.renderingScale == .portraitRelativeV1
        && nativeMinimum == Double(Float(1.777344)) && nativeMaximum == Double(Float(6.09375)),
      "all selected model variants use the same versioned virtual Portrait range")
    let expected = map.values.map {
      UInt8(((Double($0) - minimum) / (maximum - minimum) * 255).rounded())
    }
    check(stored.samples == expected, "all actual model samples quantized and attached exactly")
    check(stored.width == map.width && stored.height == map.height, "attached map geometry")
    check(
      try LosslessAVIF.decode(encoded: attached.data) == before, "final native primary unchanged")
    guard let finalSource = CGImageSourceCreateWithData(Data(attached.data) as CFData, nil),
      let finalImage = CGImageSourceCreateImageAtIndex(
        finalSource, CGImageSourceGetPrimaryImageIndex(finalSource), nil)
    else { throw DepthEstimationError.invalidImage("ImageIO cannot decode final primary") }
    check(finalImage.width == 24 && finalImage.height == 40, "ImageIO reads final primary geometry")
    guard
      let appleDisparity = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        finalSource, CGImageSourceGetPrimaryImageIndex(finalSource),
        kCGImageAuxiliaryDataTypeDisparity) as? [AnyHashable: Any]
    else { throw DepthEstimationError.invalidMap("ImageIO did not expose disparity") }
    let appleDepth = try AVDepthData(fromDictionaryRepresentation: appleDisparity)
    check(appleDepth.depthDataType == kCVPixelFormatType_DisparityFloat32, "native fdis readback")
    check(appleDepth.depthDataAccuracy == .relative, "relative accuracy survives native readback")
    check(!appleDepth.isDepthDataFiltered, "render intent does not claim filtered depth")
    check(appleDepth.cameraCalibrationData == nil, "no invented calibration")
    let context = CIContext(options: [.cacheIntermediates: false])
    guard
      let filter = context.depthBlurEffectFilter(forImageData: Data(attached.data), options: nil),
      let aperture = filter.value(forKey: "inputAperture") as? NSNumber,
      let focus = filter.value(forKey: "inputFocusRect") as? CIVector, focus.count == 4
    else {
      throw DepthEstimationError.invalidMap("public depth-blur factory cannot read render intent")
    }
    check(abs(aperture.doubleValue - 2.8) <= 0.000_001, "factory consumes simulated aperture")
    check(
      abs(focus.x - 0.45) <= 0.000_001 && abs(focus.y - 0.45) <= 0.000_001
        && abs(focus.z - 0.1) <= 0.000_001 && abs(focus.w - 0.1) <= 0.000_001,
      "factory consumes normalized centered focus area")
    let nativeMap = appleDepth.depthDataMap
    check(
      CVPixelBufferGetWidth(nativeMap) == map.width
        && CVPixelBufferGetHeight(nativeMap) == map.height,
      "native disparity retains model geometry")
    guard CVPixelBufferLockBaseAddress(nativeMap, .readOnly) == kCVReturnSuccess else {
      throw DepthEstimationError.invalidMap("cannot lock native disparity")
    }
    defer { CVPixelBufferUnlockBaseAddress(nativeMap, .readOnly) }
    let rowBytes = CVPixelBufferGetBytesPerRow(nativeMap)
    guard let base = CVPixelBufferGetBaseAddress(nativeMap), rowBytes >= map.width * 4,
      rowBytes * map.height <= CVPixelBufferGetDataSize(nativeMap)
    else { throw DepthEstimationError.invalidMap("invalid native disparity bounds") }
    var maximumULPError: Float = 0
    for y in 0..<map.height {
      for x in 0..<map.width {
        let actual = base.loadUnaligned(fromByteOffset: y * rowBytes + x * 4, as: Float.self)
        guard actual.isFinite else {
          throw DepthEstimationError.invalidMap("nonfinite native fdis")
        }
        let expected = Float(
          nativeMinimum
            + Double(stored.samples[y * map.width + x]) * (nativeMaximum - nativeMinimum) / 255)
        maximumULPError = max(
          maximumULPError, abs(actual - expected) / max(expected.ulp, Float.ulpOfOne))
      }
    }
    check(
      maximumULPError <= 4,
      "every native fdis sample matches the declared virtual reconstruction")
    if let output = ProcessInfo.processInfo.environment["PIXELBOOTH_DEPTH_VALIDATION_OUTPUT"] {
      try Data(attached.data).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    for (layout, source) in try depthNativeLayoutFixtures() {
      let original = try LosslessAVIF.decode(encoded: source)
      let inferred = try await estimator.estimate(avifData: source)
      check(
        inferred.values.count == configuration.outputWidth * configuration.outputHeight,
        "\(layout): all inferred samples available")
      let retained = try LosslessAVIF.decode(encoded: source)
      check(retained.planes == original.planes, "\(layout): native primary samples retained")
    }
  }
}

private func outputFixtureConfiguration(
  _ representation: DepthModelConfiguration.OutputRepresentation, normalized: Bool = false
) throws -> DepthModelConfiguration {
  try DepthModelConfiguration(
    modelIdentifier: "synthetic-output-adapter-\(representation.rawValue)", sourceRevision: "test",
    sourceModelSHA256: String(repeating: "0", count: 64),
    sourceWeightsSHA256: String(repeating: "1", count: 64), licenseIdentifier: "test-fixture",
    inputFeatureName: "image", inputWidth: 4, inputHeight: 4,
    outputFeatureName: "depth", outputWidth: 3, outputHeight: 2,
    outputRepresentation: representation,
    outputShape: representation == .multiArrayFloat16 || representation == .multiArrayFloat32
      ? [1, 2, 3] : nil,
    outputNormalizedByMaximum: normalized)
}

private func depthNativeLayoutFixtures() throws -> [(String, [UInt8])] {
  let width = 8
  let height = 8
  var alphaRGB = [UInt8]()
  for index in 0..<(width * height) {
    alphaRGB.append(contentsOf: [
      UInt8(index * 3 % 256), UInt8(index * 7 % 256), UInt8(index * 11 % 256),
      UInt8(index * 13 % 256),
    ])
  }
  let alphaImage = try alphaRGB.withUnsafeBytes { bytes in
    try SampleLayoutAdapter.adaptBGRA32(
      data: bytes.baseAddress!, bytesPerRow: width * 4, width: width, height: height)
  }
  defer {
    for storage in alphaImage.ownedStorage.compactMap({ $0 }) { storage.deallocate() }
  }
  let alphaAVIF = try LosslessAVIF.encodeLossless(
    alphaImage, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil,
    colorPrimaries: 1, transferCharacteristics: 13, matrixCoefficients: 0
  ).data
  var fixtures: [(String, [UInt8])] = [("RGB8 identity plus alpha", alphaAVIF)]
  for (depth, subsampled) in [(10, true), (12, false)] {
    let chromaWidth = subsampled ? width / 2 : width
    let chromaHeight = subsampled ? height / 2 : height
    let maximum = (1 << depth) - 1
    let edges = [0, 1, 16 << (depth - 8), 235 << (depth - 8), maximum - 1, maximum]
    let counts = [width * height, chromaWidth * chromaHeight, chromaWidth * chromaHeight]
    let storage = counts.map { count in
      UnsafeMutableRawPointer.allocate(byteCount: count * 2, alignment: 2)
    }
    defer { for pointer in storage { pointer.deallocate() } }
    for plane in 0..<3 {
      for index in 0..<counts[plane] {
        storage[plane].storeBytes(
          of: UInt16(edges[(index + plane) % edges.count]).littleEndian,
          toByteOffset: index * 2, as: UInt16.self)
      }
    }
    let image = PlanarImage(
      width: width, height: height, bitsPerChannel: depth,
      planes: storage.map { UnsafeRawPointer($0) },
      bytesPerRow: [width * 2, chromaWidth * 2, chromaWidth * 2],
      rowCount: [height, chromaHeight, chromaHeight], bytesPerSample: 2,
      chromaWidth: chromaWidth, chromaHeight: chromaHeight)
    let encoded = try LosslessAVIF.encodeLossless(
      image, isRGBIdentity: false, yuvRange: .limited, chromaLocation: nil,
      colorPrimaries: 1, transferCharacteristics: 1, matrixCoefficients: 1
    ).data
    fixtures.append(("YUV\(subsampled ? "420" : "444") limited \(depth)-bit edge samples", encoded))
  }
  return fixtures
}

/// Generated nonphotographic fixture with an asymmetric portrait field.
private func depthInferenceFixture(xmp: [UInt8]? = nil) throws -> [UInt8] {
  let width = 24
  let height = 40
  var rgb = [UInt8]()
  for y in 0..<height {
    for x in 0..<width {
      rgb.append(UInt8(x * 255 / (width - 1)))
      rgb.append(UInt8(y * 255 / (height - 1)))
      rgb.append((x > 4 && x < 14 && y > 10 && y < 35) ? 220 : 32)
    }
  }
  return try encodeDepthRGBFixture(rgb, width: width, height: height, xmp: xmp)
}

private func encodeDepthRGBFixture(
  _ rgb: [UInt8], width: Int, height: Int, xmp: [UInt8]? = nil
) throws -> [UInt8] {
  let image = try rgb.withUnsafeBytes { raw in
    try SampleLayoutAdapter.adaptRGB24(
      data: raw.baseAddress!, bytesPerRow: width * 3, width: width, height: height)
  }
  defer {
    for storage in image.ownedStorage.compactMap({ $0 }) { storage.deallocate() }
  }
  return try LosslessAVIF.encodeLossless(
    image, isRGBIdentity: true, yuvRange: nil, chromaLocation: nil,
    colorPrimaries: 1, transferCharacteristics: 13, matrixCoefficients: 0, xmpPayload: xmp
  ).data
}
