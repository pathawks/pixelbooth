import CoreML
import CoreVideo
import Darwin
import Foundation

/// Build-time Core ML preparation through public APIs available with Command Line Tools.
@main
struct CompileDepthModel {
  private struct PreparationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count >= 2,
        arguments[0] == "metadata" || arguments[0] == "compile",
        arguments.count == (arguments[0] == "metadata" ? 2 : 3)
      else {
        throw PreparationError(
          message: "Usage: compile-depth-model metadata MODEL | compile MODEL OUTPUT_DIRECTORY")
      }
      let source = URL(fileURLWithPath: arguments[1])
      let compiled = try await MLModel.compileModel(at: source)
      defer { try? FileManager.default.removeItem(at: compiled) }
      if arguments[0] == "compile" {
        let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)
          .appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mlmodelc")
        try FileManager.default.copyItem(at: compiled, to: destination)
      } else {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let description = model.modelDescription
        let metadata: [[String: Any]] = [
          [
            "inputSchema": description.inputDescriptionsByName.sorted { $0.key < $1.key }
              .map { featureMetadata($0.value) },
            "outputSchema": description.outputDescriptionsByName.sorted { $0.key < $1.key }
              .map { featureMetadata($0.value) },
            "version": description.metadata[.versionString] as? String ?? "",
          ]
        ]
        var encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        encoded.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: encoded)
      }
    } catch {
      try? FileHandle.standardError.write(
        contentsOf: Data("Core ML model preparation failed: \(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }

  private static func featureMetadata(_ feature: MLFeatureDescription) -> [String: Any] {
    if let image = feature.imageConstraint {
      let colorSpace: String
      switch image.pixelFormatType {
      case kCVPixelFormatType_32BGRA: colorSpace = "RGB"
      case kCVPixelFormatType_OneComponent16Half: colorSpace = "Grayscale16Half"
      case kCVPixelFormatType_OneComponent32Float: colorSpace = "Grayscale32Float"
      default: colorSpace = "Unsupported"
      }
      return [
        "name": feature.name, "type": "Image", "colorspace": colorSpace,
        "width": image.pixelsWide, "height": image.pixelsHigh,
        "hasSizeFlexibility": fixedImageSize(image) ? "0" : "1",
      ]
    }
    if let array = feature.multiArrayConstraint {
      let dataType: String
      switch array.dataType {
      case .float16: dataType = "Float16"
      case .float32: dataType = "Float32"
      default: dataType = "Unsupported"
      }
      let shape = array.shape.map(\.intValue)
      let encodedShape = try? JSONSerialization.data(withJSONObject: shape)
      return [
        "name": feature.name, "type": "MultiArray", "dataType": dataType,
        "shape": encodedShape.flatMap { String(data: $0, encoding: .utf8) } ?? "null",
        "hasShapeFlexibility": fixedArrayShape(array) ? "0" : "1",
      ]
    }
    return ["name": feature.name, "type": "Unsupported"]
  }

  private static func fixedImageSize(_ image: MLImageConstraint) -> Bool {
    let constraint = image.sizeConstraint
    switch constraint.type {
    case .enumerated:
      return !constraint.enumeratedImageSizes.isEmpty
        && constraint.enumeratedImageSizes.allSatisfy {
          $0.pixelsWide == image.pixelsWide && $0.pixelsHigh == image.pixelsHigh
        }
    case .range:
      return constraint.pixelsWideRange == NSRange(location: image.pixelsWide, length: 1)
        && constraint.pixelsHighRange == NSRange(location: image.pixelsHigh, length: 1)
    default: return false
    }
  }

  private static func fixedArrayShape(_ array: MLMultiArrayConstraint) -> Bool {
    let constraint = array.shapeConstraint
    switch constraint.type {
    case .enumerated:
      return !constraint.enumeratedShapes.isEmpty
        && constraint.enumeratedShapes.allSatisfy { $0 == array.shape }
    case .range:
      return constraint.sizeRangeForDimension.count == array.shape.count
        && zip(constraint.sizeRangeForDimension, array.shape).allSatisfy {
          $0.0.rangeValue == NSRange(location: $0.1.intValue, length: 1)
        }
    default: return false
    }
  }
}
