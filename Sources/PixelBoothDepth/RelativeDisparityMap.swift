import Foundation

/// Inspectable inference-only pixels after full-field resize and sRGB conversion.
/// Rows follow the source sample order; bytes are tightly packed B,G,R,A with opaque A.
public struct DepthInferenceInput: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let bgraPixels: [UInt8]

}

/// An application-generated relative inverse-depth estimate, with larger values nearer.
/// Normalization follows the selected model; these are not distances or calibrated camera data.
public struct RelativeDisparityMap: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let values: [Float]
  public let configuration: DepthModelConfiguration?

  public init(
    width: Int, height: Int, values: [Float], configuration: DepthModelConfiguration? = nil
  ) throws {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, count <= 1_048_576, values.count == count else {
      throw DepthEstimationError.invalidMap("invalid or excessive geometry")
    }
    if let configuration {
      try configuration.validate()
      guard width == configuration.outputWidth, height == configuration.outputHeight else {
        throw DepthEstimationError.invalidMap("samples differ from configured output geometry")
      }
    }
    let normalized = configuration?.outputNormalizedByMaximum ?? true
    guard values.allSatisfy({ $0.isFinite && $0 >= 0 && (!normalized || $0 <= 1) }) else {
      throw DepthEstimationError.invalidMap(
        normalized
          ? "samples must be finite model-normalized values in 0...1"
          : "samples must be finite nonnegative relative inverse depth")
    }
    self.width = width
    self.height = height
    self.values = values
    self.configuration = configuration
  }

  public var modelIdentifier: String { configuration?.provenanceIdentifier ?? "unspecified-model" }
  public var preprocessingDescription: String? { configuration?.preprocessingDescription }
  public var outputDescription: String? { configuration?.outputDescription }
}

public enum DepthEstimationError: Error, Equatable, Sendable, LocalizedError {
  case modelUnavailable
  case invalidModel(String)
  case invalidImage(String)
  case invalidMap(String)

  public var errorDescription: String? {
    switch self {
    case .modelUnavailable:
      return
        "The bundled Depth Anything V2 model is unavailable. Rebuild the app with its pinned model."
    case .invalidModel(let detail): return "Unsupported Depth Anything V2 model: \(detail)"
    case .invalidImage(let detail): return "Cannot derive disparity from the AVIF image: \(detail)"
    case .invalidMap(let detail):
      return "Depth Anything V2 produced an invalid disparity map: \(detail)"
    }
  }
}
