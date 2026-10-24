import Foundation

/// Build-selected model identity and the exact input/output contract bundled beside it.
public struct DepthModelConfiguration: Codable, Sendable, Equatable {
  public enum OutputRepresentation: String, Codable, Sendable {
    case imageFloat16
    case imageFloat32
    case multiArrayFloat16
    case multiArrayFloat32
  }

  public let schemaVersion: Int
  public let modelResourceName: String
  public let modelIdentifier: String
  public let sourceRevision: String
  public let sourceModelSHA256: String
  public let sourceWeightsSHA256: String
  public let licenseIdentifier: String
  public let inputFeatureName: String
  public let inputWidth: Int
  public let inputHeight: Int
  public let outputFeatureName: String
  public let outputWidth: Int
  public let outputHeight: Int
  public let outputRepresentation: OutputRepresentation
  public let outputShape: [Int]?
  public let outputNormalizedByMaximum: Bool
  public let modelVersionString: String?

  public init(
    schemaVersion: Int = 1, modelResourceName: String = "PixelBoothDepth",
    modelIdentifier: String, sourceRevision: String, sourceModelSHA256: String,
    sourceWeightsSHA256: String, licenseIdentifier: String,
    inputFeatureName: String, inputWidth: Int, inputHeight: Int,
    outputFeatureName: String, outputWidth: Int, outputHeight: Int,
    outputRepresentation: OutputRepresentation, outputShape: [Int]? = nil,
    outputNormalizedByMaximum: Bool, modelVersionString: String? = nil
  ) throws {
    self.schemaVersion = schemaVersion
    self.modelResourceName = modelResourceName
    self.modelIdentifier = modelIdentifier
    self.sourceRevision = sourceRevision
    self.sourceModelSHA256 = sourceModelSHA256
    self.sourceWeightsSHA256 = sourceWeightsSHA256
    self.licenseIdentifier = licenseIdentifier
    self.inputFeatureName = inputFeatureName
    self.inputWidth = inputWidth
    self.inputHeight = inputHeight
    self.outputFeatureName = outputFeatureName
    self.outputWidth = outputWidth
    self.outputHeight = outputHeight
    self.outputRepresentation = outputRepresentation
    self.outputShape = outputShape
    self.outputNormalizedByMaximum = outputNormalizedByMaximum
    self.modelVersionString = modelVersionString
    try validate()
  }

  /// Fixture configuration only. Production resolves the build-generated descriptor.
  public static let smallF16 = try! DepthModelConfiguration(
    modelIdentifier:
      "apple/coreml-depth-anything-v2-small/DepthAnythingV2SmallF16@cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
    sourceRevision: "cfef6f6f2a70783dedc0bfae40cecbc2052285d3",
    sourceModelSHA256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042",
    sourceWeightsSHA256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed",
    licenseIdentifier: "Apache-2.0", inputFeatureName: "image", inputWidth: 518, inputHeight: 392,
    outputFeatureName: "depth", outputWidth: 518, outputHeight: 392,
    outputRepresentation: .imageFloat16, outputNormalizedByMaximum: true,
    modelVersionString: "2.0")

  public var preprocessingDescription: String {
    "ImageIO-derived 8-bit sRGB; alpha composited on black; full-field stretch to \(inputWidth)x\(inputHeight) (aspect distortion possible); no crop, mirror, or orientation transform"
  }

  /// Stable source facts accompany even a locally chosen friendly model identifier.
  public var provenanceIdentifier: String {
    "\(modelIdentifier); sourceRevision=\(sourceRevision); sourceModelSHA256=\(sourceModelSHA256); sourceWeightsSHA256=\(sourceWeightsSHA256); license=\(licenseIdentifier)"
  }

  public var outputDescription: String {
    let normalization =
      outputNormalizedByMaximum
      ? "normalized by the model's per-image maximum" : "unnormalized model values"
    return
      "Model-generated relative inverse depth, \(normalization); larger values nearer; not metric or camera-measured; output=\(outputRepresentation.rawValue); license=\(licenseIdentifier)"
  }

  /// Parses a bounded descriptor and rejects invalid contracts before loading a model.
  public static func load(from url: URL) throws -> DepthModelConfiguration {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DepthEstimationError.modelUnavailable
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= 65_536 else {
      throw DepthEstimationError.invalidModel("configuration exceeds the descriptor size limit")
    }
    let configuration: DepthModelConfiguration
    do { configuration = try JSONDecoder().decode(Self.self, from: data) } catch {
      throw DepthEstimationError.invalidModel("invalid configuration JSON: \(error)")
    }
    try configuration.validate()
    return configuration
  }

  public func validate() throws {
    guard schemaVersion == 1, modelResourceName == "PixelBoothDepth",
      Self.validText(modelIdentifier), Self.validText(sourceRevision),
      Self.validText(provenanceIdentifier),
      Self.validHash(sourceModelSHA256), Self.validHash(sourceWeightsSHA256),
      Self.validText(licenseIdentifier), Self.validText(inputFeatureName),
      Self.validText(outputFeatureName), modelVersionString.map(Self.validText) ?? true,
      Self.validGeometry(inputWidth, inputHeight), Self.validGeometry(outputWidth, outputHeight)
    else { throw DepthEstimationError.invalidModel("invalid model identity, version, or geometry") }
    switch outputRepresentation {
    case .imageFloat16, .imageFloat32:
      guard outputShape == nil else {
        throw DepthEstimationError.invalidModel("image output must not declare an array shape")
      }
    case .multiArrayFloat16, .multiArrayFloat32:
      guard let outputShape, (2...4).contains(outputShape.count),
        Array(outputShape.suffix(2)) == [outputHeight, outputWidth],
        outputShape.dropLast(2).allSatisfy({ $0 == 1 })
      else { throw DepthEstimationError.invalidModel("unsupported array output shape") }
    }
  }

  private static func validText(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096
      && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }

  private static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func validGeometry(_ width: Int, _ height: Int) -> Bool {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    return width > 0 && height > 0 && width <= 4_096 && height <= 4_096
      && !overflow && count <= 1_048_576
  }
}
