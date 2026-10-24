import Foundation

/// Application-selected instructions for an external Portrait renderer.
/// These values do not describe camera focus, camera aperture, or image quality.
public struct PortraitRenderIntent: Hashable, Sendable, Codable {
  public enum Origin: String, Sendable, Codable {
    case applicationDefault = "application-default"
    case applicationChosen = "application-chosen"
  }

  public enum ValidationError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion
    case invalidDimensions
    case invalidAperture
    case invalidFocusRegion
    case defaultOriginMismatch

    public var errorDescription: String? {
      switch self {
      case .unsupportedVersion: "The Portrait render-intent version is unsupported."
      case .invalidDimensions: "The Portrait render intent has invalid primary image dimensions."
      case .invalidAperture:
        "The simulated aperture must be finite, greater than zero, and at most 64."
      case .invalidFocusRegion: "The normalized focus rectangle must lie within the primary image."
      case .defaultOriginMismatch:
        "Nondefault Portrait render parameters must be labeled application-chosen."
      }
    }
  }

  public static let currentVersion = 1
  public let version: Int
  public let primaryWidth: Int
  public let primaryHeight: Int
  public let simulatedAperture: Double
  /// Rectangle center and extent in normalized, top-left primary-image coordinates.
  public let focusCenterX: Double
  public let focusCenterY: Double
  public let focusWidth: Double
  public let focusHeight: Double
  public let origin: Origin

  public init(
    primaryWidth: Int, primaryHeight: Int,
    simulatedAperture: Double = 2.8,
    focusCenterX: Double = 0.5, focusCenterY: Double = 0.5,
    focusWidth: Double = 0.1, focusHeight: Double = 0.1,
    origin: Origin = .applicationDefault
  ) throws {
    let (_, overflow) = primaryWidth.multipliedReportingOverflow(by: primaryHeight)
    guard primaryWidth > 0, primaryHeight > 0,
      UInt32(exactly: primaryWidth) != nil, UInt32(exactly: primaryHeight) != nil, !overflow
    else { throw ValidationError.invalidDimensions }
    guard simulatedAperture.isFinite, simulatedAperture > 0, simulatedAperture <= 64 else {
      throw ValidationError.invalidAperture
    }
    guard [focusCenterX, focusCenterY, focusWidth, focusHeight].allSatisfy(\.isFinite),
      focusWidth > 0, focusWidth <= 1, focusHeight > 0, focusHeight <= 1,
      focusCenterX >= focusWidth / 2, focusCenterX <= 1 - focusWidth / 2,
      focusCenterY >= focusHeight / 2, focusCenterY <= 1 - focusHeight / 2
    else { throw ValidationError.invalidFocusRegion }
    guard
      origin != .applicationDefault
        || (simulatedAperture == 2.8 && focusCenterX == 0.5 && focusCenterY == 0.5
          && focusWidth == 0.1 && focusHeight == 0.1)
    else { throw ValidationError.defaultOriginMismatch }
    self.version = Self.currentVersion
    self.primaryWidth = primaryWidth
    self.primaryHeight = primaryHeight
    self.simulatedAperture = simulatedAperture
    self.focusCenterX = focusCenterX
    self.focusCenterY = focusCenterY
    self.focusWidth = focusWidth
    self.focusHeight = focusHeight
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case primaryWidth
    case primaryHeight
    case simulatedAperture
    case focusCenterX
    case focusCenterY
    case focusWidth
    case focusHeight
    case origin
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
      throw ValidationError.unsupportedVersion
    }
    try self.init(
      primaryWidth: values.decode(Int.self, forKey: .primaryWidth),
      primaryHeight: values.decode(Int.self, forKey: .primaryHeight),
      simulatedAperture: values.decode(Double.self, forKey: .simulatedAperture),
      focusCenterX: values.decode(Double.self, forKey: .focusCenterX),
      focusCenterY: values.decode(Double.self, forKey: .focusCenterY),
      focusWidth: values.decode(Double.self, forKey: .focusWidth),
      focusHeight: values.decode(Double.self, forKey: .focusHeight),
      origin: values.decode(Origin.self, forKey: .origin))
  }
}
