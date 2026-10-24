import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

/// Serial on-device inference on an image derived from the finalized primary AVIF.
/// ImageIO/Core ML RGB conversion and full-field resizing serve inference only;
/// none of the resulting pixels feed the archival primary image encoder.
public actor DepthAnythingV2Estimator {
  private let explicitModelURL: URL?
  private let configurationURL: URL?
  private var selectedConfiguration: DepthModelConfiguration?
  private var model: MLModel?
  private static let maximumSourcePixels = 100_000_000
  private static let maximumEncodedBytes = 512 * 1_024 * 1_024

  /// The default resolves the compiled model from the standalone app's resources.
  /// An explicit URL supports headless fixture tests without the application bundle.
  public init(configurationURL: URL? = nil, modelURL: URL? = nil) {
    self.configurationURL =
      configurationURL ?? Bundle.main.url(forResource: "DepthModel", withExtension: "json")
    self.explicitModelURL = modelURL
  }

  public init(configuration: DepthModelConfiguration, modelURL: URL? = nil) {
    self.selectedConfiguration = configuration
    self.configurationURL = nil
    self.explicitModelURL = modelURL
  }

  /// Returns the selected model's map over the untransformed primary sample field.
  /// Failure propagates to the recoverable capture job; requested maps are never omitted.
  public func estimate(avifData: [UInt8]) throws -> RelativeDisparityMap {
    try Task.checkCancellation()
    let configuration = try loadConfiguration()
    let pixels = try Self.makeInferenceInput(avifData: avifData, configuration: configuration)
    let input = try Self.featureValue(pixels)
    let loadedModel = try loadModel(configuration: configuration)
    try Task.checkCancellation()
    let prediction = try loadedModel.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [configuration.inputFeatureName: input]))
    try Task.checkCancellation()
    guard let output = prediction.featureValue(for: configuration.outputFeatureName) else {
      throw DepthEstimationError.invalidMap("missing configured output")
    }
    return try Self.relativeDisparity(from: output, configuration: configuration)
  }

  /// Exposes the exact derived input used by inference for geometry/color validation.
  /// This full-field stretch retains all source content and never applies metadata orientation.
  public static func makeInferenceInput(
    avifData: [UInt8], configuration: DepthModelConfiguration = .smallF16
  ) throws -> DepthInferenceInput {
    try configuration.validate()
    let width = configuration.inputWidth
    let height = configuration.inputHeight
    guard !avifData.isEmpty, avifData.count <= Self.maximumEncodedBytes,
      let source = CGImageSourceCreateWithData(
        Data(avifData) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) as String? == "public.avif"
    else { throw DepthEstimationError.invalidImage("unreadable AVIF data") }
    let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
    guard primaryIndex < CGImageSourceGetCount(source),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil)
        as? [CFString: Any],
      let sourceWidthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let sourceHeightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else { throw DepthEstimationError.invalidImage("primary image geometry is unavailable") }
    let sourceWidth = sourceWidthNumber.int64Value
    let sourceHeight = sourceHeightNumber.int64Value
    let (sourcePixels, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
    guard sourceWidth > 0, sourceHeight > 0, !overflow,
      sourcePixels <= Self.maximumSourcePixels
    else {
      throw DepthEstimationError.invalidImage("primary image exceeds the inference memory limit")
    }
    guard
      let image = CGImageSourceCreateImageAtIndex(
        source, primaryIndex, [kCGImageSourceShouldCache: false] as CFDictionary),
      image.width == sourceWidth, image.height == sourceHeight
    else { throw DepthEstimationError.invalidImage("primary image RGB decode failed") }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw DepthEstimationError.invalidImage("cannot create derived sRGB input") }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let base = context.data else {
      throw DepthEstimationError.invalidImage("derived sRGB input has no storage")
    }
    var pixels = [UInt8](
      UnsafeRawBufferPointer(start: base, count: width * height * 4))
    for alphaIndex in stride(from: 3, to: pixels.count, by: 4) { pixels[alphaIndex] = 255 }
    return DepthInferenceInput(width: width, height: height, bgraPixels: pixels)
  }

  private static func featureValue(_ pixels: DepthInferenceInput) throws -> MLFeatureValue {
    let width = pixels.width
    let height = pixels.height
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer,
      CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
    else { throw DepthEstimationError.invalidImage("cannot create model input buffer") }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let (required, overflow) = rowStride.multipliedReportingOverflow(by: height)
    guard !overflow, rowStride >= width * 4, required <= CVPixelBufferGetDataSize(pixelBuffer),
      let base = CVPixelBufferGetBaseAddress(pixelBuffer)
    else { throw DepthEstimationError.invalidImage("invalid model input buffer bounds") }
    pixels.bgraPixels.withUnsafeBytes { source in
      for y in 0..<height {
        base.advanced(by: y * rowStride).copyMemory(
          from: source.baseAddress!.advanced(by: y * width * 4), byteCount: width * 4)
      }
    }
    return MLFeatureValue(pixelBuffer: pixelBuffer)
  }

  private func loadConfiguration() throws -> DepthModelConfiguration {
    if let selectedConfiguration {
      try selectedConfiguration.validate()
      return selectedConfiguration
    }
    guard let configurationURL else { throw DepthEstimationError.modelUnavailable }
    let configuration = try DepthModelConfiguration.load(from: configurationURL)
    selectedConfiguration = configuration
    return configuration
  }

  private func loadModel(configuration: DepthModelConfiguration) throws -> MLModel {
    if let model { return model }
    guard
      let modelURL = explicitModelURL
        ?? Bundle.main.url(forResource: configuration.modelResourceName, withExtension: "mlmodelc"),
      FileManager.default.fileExists(atPath: modelURL.path)
    else {
      throw DepthEstimationError.modelUnavailable
    }
    let computeConfiguration = MLModelConfiguration()
    computeConfiguration.computeUnits = .all
    let loaded = try MLModel(contentsOf: modelURL, configuration: computeConfiguration)
    guard loaded.modelDescription.inputDescriptionsByName.count == 1,
      let input = loaded.modelDescription.inputDescriptionsByName[configuration.inputFeatureName]?
        .imageConstraint,
      input.pixelsWide == configuration.inputWidth, input.pixelsHigh == configuration.inputHeight,
      input.pixelFormatType == kCVPixelFormatType_32BGRA,
      loaded.modelDescription.outputDescriptionsByName.count == 1,
      let output = loaded.modelDescription.outputDescriptionsByName[
        configuration.outputFeatureName],
      configuration.modelVersionString == nil
        || loaded.modelDescription.metadata[.versionString] as? String
          == configuration.modelVersionString
    else { throw DepthEstimationError.invalidModel("unexpected input/output schema or version") }
    switch configuration.outputRepresentation {
    case .imageFloat16, .imageFloat32:
      let expectedFormat =
        configuration.outputRepresentation == .imageFloat16
        ? kCVPixelFormatType_OneComponent16Half : kCVPixelFormatType_OneComponent32Float
      guard let image = output.imageConstraint,
        image.pixelsWide == configuration.outputWidth,
        image.pixelsHigh == configuration.outputHeight,
        image.pixelFormatType == expectedFormat
      else { throw DepthEstimationError.invalidModel("image output differs from configuration") }
    case .multiArrayFloat16, .multiArrayFloat32:
      let expectedType: MLMultiArrayDataType =
        configuration.outputRepresentation == .multiArrayFloat16 ? .float16 : .float32
      guard let array = output.multiArrayConstraint,
        array.shape.map(\.intValue) == configuration.outputShape, array.dataType == expectedType
      else { throw DepthEstimationError.invalidModel("array output differs from configuration") }
    }
    model = loaded
    return loaded
  }

  /// Copies the exact declared model samples, respecting padded rows and array strides.
  public static func relativeDisparity(
    from output: MLFeatureValue, configuration: DepthModelConfiguration
  ) throws -> RelativeDisparityMap {
    try configuration.validate()
    switch configuration.outputRepresentation {
    case .imageFloat16, .imageFloat32:
      guard let image = output.imageBufferValue else {
        throw DepthEstimationError.invalidMap("missing configured image output")
      }
      return try copyImageMap(image, configuration: configuration)
    case .multiArrayFloat16, .multiArrayFloat32:
      guard let array = output.multiArrayValue else {
        throw DepthEstimationError.invalidMap("missing configured array output")
      }
      return try copyArrayMap(array, configuration: configuration)
    }
  }

  private static func copyImageMap(
    _ buffer: CVPixelBuffer, configuration: DepthModelConfiguration
  ) throws -> RelativeDisparityMap {
    let width = configuration.outputWidth
    let height = configuration.outputHeight
    let halfFloat = configuration.outputRepresentation == .imageFloat16
    let sampleBytes = halfFloat ? 2 : 4
    let expectedFormat =
      halfFloat ? kCVPixelFormatType_OneComponent16Half : kCVPixelFormatType_OneComponent32Float
    guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
      !CVPixelBufferIsPlanar(buffer),
      CVPixelBufferGetPixelFormatType(buffer) == expectedFormat
    else { throw DepthEstimationError.invalidMap("unexpected geometry or sample format") }
    let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard status == kCVReturnSuccess else {
      throw DepthEstimationError.invalidMap("cannot lock depth samples")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let (requiredBytes, overflow) = stride.multipliedReportingOverflow(by: height)
    guard !overflow, stride >= width * sampleBytes,
      requiredBytes <= CVPixelBufferGetDataSize(buffer),
      let base = CVPixelBufferGetBaseAddress(buffer)
    else { throw DepthEstimationError.invalidMap("invalid sample buffer bounds") }
    var values = [Float]()
    values.reserveCapacity(width * height)
    for y in 0..<height {
      let row = base.advanced(by: y * stride)
      for x in 0..<width {
        values.append(
          halfFloat
            ? Float(Float16(bitPattern: row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)))
            : row.loadUnaligned(fromByteOffset: x * 4, as: Float.self))
      }
    }
    return try RelativeDisparityMap(
      width: width, height: height, values: values, configuration: configuration)
  }

  private static func copyArrayMap(
    _ array: MLMultiArray, configuration: DepthModelConfiguration
  ) throws -> RelativeDisparityMap {
    let width = configuration.outputWidth
    let height = configuration.outputHeight
    let halfFloat = configuration.outputRepresentation == .multiArrayFloat16
    let expectedType: MLMultiArrayDataType = halfFloat ? .float16 : .float32
    let sampleBytes = halfFloat ? 2 : 4
    let shape = array.shape.map(\.intValue)
    let strides = array.strides.map(\.intValue)
    guard shape == configuration.outputShape, array.dataType == expectedType,
      array.count == width * height, strides.count == shape.count,
      strides.allSatisfy({ $0 > 0 })
    else { throw DepthEstimationError.invalidMap("array schema differs from configuration") }
    let rowStride = strides[strides.count - 2]
    let columnStride = strides[strides.count - 1]
    let (rowOffset, rowOverflow) = (height - 1).multipliedReportingOverflow(by: rowStride)
    let (columnOffset, columnOverflow) = (width - 1).multipliedReportingOverflow(by: columnStride)
    let (lastSample, sampleOverflow) = rowOffset.addingReportingOverflow(columnOffset)
    let (lastByte, byteOverflow) = lastSample.multipliedReportingOverflow(by: sampleBytes)
    let (requiredBytes, sizeOverflow) = lastByte.addingReportingOverflow(sampleBytes)
    guard !rowOverflow, !columnOverflow, !sampleOverflow, !byteOverflow, !sizeOverflow else {
      throw DepthEstimationError.invalidMap("array strides exceed addressable bounds")
    }
    let values = try array.withUnsafeBytes { bytes -> [Float] in
      guard requiredBytes <= bytes.count else {
        throw DepthEstimationError.invalidMap("array strides exceed sample storage")
      }
      var samples = [Float]()
      samples.reserveCapacity(width * height)
      for y in 0..<height {
        for x in 0..<width {
          let offset = (y * rowStride + x * columnStride) * sampleBytes
          samples.append(
            halfFloat
              ? Float(
                Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
              : bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
        }
      }
      return samples
    }
    return try RelativeDisparityMap(
      width: width, height: height, values: values, configuration: configuration)
  }
}
