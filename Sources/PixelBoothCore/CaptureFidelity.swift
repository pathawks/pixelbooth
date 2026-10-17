import Foundation

/// Facts derived only from byte-exact, understood FourCCs. Unknown layouts
/// remain unknown; they are never assigned the common 8-bit default.
public enum CaptureFormatFacts {
  public static func isConsistent(_ input: CaptureFormat) -> Bool {
    let knownRGB = PixelFormatFourCC.isRGB(input.fourCC)
    let known = PixelFormatFourCC.codecFamily(input.fourCC) != .unknown
    guard known else { return true }
    let expected = applying(
      to: CaptureFormat(width: input.width, height: input.height, fourCC: input.fourCC))
    if let value = input.bitsPerChannel, let expectedValue = expected.bitsPerChannel,
      value != expectedValue
    {
      return false
    }
    if let value = input.chromaSampling, let expectedValue = expected.chromaSampling,
      value != expectedValue
    {
      return false
    }
    if let value = input.yuvRange, let expectedValue = expected.yuvRange, value != expectedValue {
      return false
    }
    if knownRGB && (input.chromaSampling != nil || input.yuvRange != nil) { return false }
    return true
  }

  public static func applying(to input: CaptureFormat) -> CaptureFormat {
    var format = input
    switch input.fourCC {
    case 0x3432_3076:  // CoreVideo '420v'
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv420
      format.yuvRange = format.yuvRange ?? .limited
    case 0x3432_3066:  // CoreVideo '420f'
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv420
      format.yuvRange = format.yuvRange ?? .full
    case 0x4e56_3132:  // 'NV12'; range is not implied
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv420
    case 0x3276_7579:  // CoreVideo '2vuy'
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv422
      format.yuvRange = format.yuvRange ?? .limited
    case 0x7975_7673:  // CoreVideo 'yuvs'
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv422
      format.yuvRange = format.yuvRange ?? .limited
    case 0x4247_5241, 0x5247_4241, PixelFormatFourCC.rgb24, PixelFormatFourCC.bgr24,
      0x4142_4752:  // BGRA / RGBA / 24RGB / 24BG / ABGR
      format.bitsPerChannel = format.bitsPerChannel ?? 8
    case PixelFormatFourCC.v210:  // CoreVideo 'v210'
      format.bitsPerChannel = 10
      format.chromaSampling = .yuv422
    case PixelFormatFourCC.x420:  // CoreVideo video-range 10-bit 4:2:0
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv420
      format.yuvRange = format.yuvRange ?? .limited
    case PixelFormatFourCC.xf20:  // CoreVideo full-range 10-bit 4:2:0
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv420
      format.yuvRange = format.yuvRange ?? .full
    case PixelFormatFourCC.x422:  // CoreVideo video-range 10-bit 4:2:2
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv422
      format.yuvRange = format.yuvRange ?? .limited
    case PixelFormatFourCC.xf22:  // CoreVideo full-range 10-bit 4:2:2
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv422
      format.yuvRange = format.yuvRange ?? .full
    case PixelFormatFourCC.x444:  // CoreVideo video-range 10-bit 4:4:4
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv444
      format.yuvRange = format.yuvRange ?? .limited
    case PixelFormatFourCC.xf44:  // CoreVideo full-range 10-bit 4:4:4
      format.bitsPerChannel = format.bitsPerChannel ?? 10
      format.chromaSampling = format.chromaSampling ?? .yuv444
      format.yuvRange = format.yuvRange ?? .full
    case PixelFormatFourCC.y420:  // CoreVideo planar 8-bit 4:2:0
      format.bitsPerChannel = format.bitsPerChannel ?? 8
      format.chromaSampling = format.chromaSampling ?? .yuv420
    case PixelFormatFourCC.mjpeg, PixelFormatFourCC.jpeg, PixelFormatFourCC.dmb1:
      // JPEG coding family; JPEG precision is read from the bitstream.
      break
    case 0x6176_6331:  // H.264 coding family; decoded output facts are separate
      break
    default:
      // Preserve independently established facts for unknown FourCCs. Their
      // absence must remain unknown, rather than being filled or erased here.
      break
    }
    return format
  }
}

/// Evidence saved with a capture. This describes preservation from the
/// macOS-delivered buffer and does not imply sensor- or USB-level identity.
public struct AcquisitionEvidence: Hashable, Sendable, Codable {
  public var deviceUniqueID: String
  public var generation: Int
  public var selectedFormat: CaptureFormat
  public var deliveredFormat: CaptureFormat
  public var fidelity: AcquisitionFidelity
  public var knownConversions: [String]

  public init(
    deviceUniqueID: String, generation: Int, selectedFormat: CaptureFormat,
    deliveredFormat: CaptureFormat, fidelity: AcquisitionFidelity,
    knownConversions: [String]
  ) {
    self.deviceUniqueID = deviceUniqueID
    self.generation = generation
    self.selectedFormat = selectedFormat
    self.deliveredFormat = deliveredFormat
    self.fidelity = fidelity
    self.knownConversions = knownConversions
  }
}

public enum CaptureFidelityError: Error, Equatable, LocalizedError, Sendable {
  case contradictoryFourCCFacts(UInt32)
  case staleDevice(expected: String, delivered: String)
  case staleGeneration(expected: Int, delivered: Int)
  case dimensionsChanged(selected: String, delivered: String)
  case bitDepthChanged(selected: Int, delivered: Int)
  case colorModelChanged(selected: String, delivered: String)
  case chromaChanged(selected: String, delivered: String)
  case rangeChanged(selected: String, delivered: String)
  case chromaLocationChanged(selected: String, delivered: String)
  case jpegCodingDataUnavailable(selected: String, delivered: String)

  public var errorDescription: String? {
    switch self {
    case .contradictoryFourCCFacts(let fourCC):
      return
        "The reported facts contradict the \(CaptureFormat.fourCCString(fourCC)) representation."
    case .staleDevice(let expected, let delivered):
      return "The frame came from camera \(delivered), but camera \(expected) is selected."
    case .staleGeneration(let expected, let delivered):
      return
        "The frame belongs to configuration \(delivered), but configuration \(expected) is active."
    case .dimensionsChanged(let selected, let delivered):
      return "The selected dimensions are \(selected), but macOS delivered \(delivered)."
    case .bitDepthChanged(let selected, let delivered):
      return "The selected bit depth is \(selected), but macOS delivered \(delivered)."
    case .colorModelChanged(let selected, let delivered):
      return "The selected color model is \(selected), but macOS delivered \(delivered)."
    case .chromaChanged(let selected, let delivered):
      return "The selected chroma sampling is \(selected), but macOS delivered \(delivered)."
    case .rangeChanged(let selected, let delivered):
      return "The selected YUV range is \(selected), but macOS delivered \(delivered)."
    case .chromaLocationChanged(let selected, let delivered):
      return "The selected chroma location is \(selected), but macOS delivered \(delivered)."
    case .jpegCodingDataUnavailable(let selected, let delivered):
      return
        "The selected \(selected) mode requires camera JPEG coding data, but macOS delivered \(delivered). Select a mode that delivers JPEG data or choose the delivered mode explicitly."
    }
  }
}

public enum AcquisitionPolicy {
  /// Compare only known properties. An exact FourCC match is not proof of
  /// USB-native delivery; unknown upstream behavior remains clearly classified.
  public static func evaluate(
    deviceUniqueID: String, generation: Int,
    expectedDeviceID: String, expectedGeneration: Int,
    selected: CaptureFormat, delivered: CaptureFormat,
    upstreamNoConversionEstablished: Bool = false
  ) throws -> AcquisitionEvidence {
    guard deviceUniqueID == expectedDeviceID else {
      throw CaptureFidelityError.staleDevice(expected: expectedDeviceID, delivered: deviceUniqueID)
    }
    guard generation == expectedGeneration else {
      throw CaptureFidelityError.staleGeneration(
        expected: expectedGeneration, delivered: generation)
    }
    guard CaptureFormatFacts.isConsistent(selected), CaptureFormatFacts.isConsistent(delivered)
    else {
      throw CaptureFidelityError.contradictoryFourCCFacts(selected.fourCC)
    }
    let selected = CaptureFormatFacts.applying(to: selected)
    let delivered = CaptureFormatFacts.applying(to: delivered)
    let selectedFamily = PixelFormatFourCC.codecFamily(selected.fourCC)
    let deliveredFamily = PixelFormatFourCC.codecFamily(delivered.fourCC)
    if selectedFamily == .nativeJPEG && deliveredFamily != .nativeJPEG {
      throw CaptureFidelityError.jpegCodingDataUnavailable(
        selected: CaptureFormat.fourCCString(selected.fourCC),
        delivered: CaptureFormat.fourCCString(delivered.fourCC))
    }
    func model(_ f: CaptureFormat) -> String? {
      switch PixelFormatFourCC.codecFamily(f.fourCC) {
      case .uncompressedRGB: return "RGB"
      case .uncompressedYUV: return "YUV"
      default:
        if f.chromaSampling != nil || f.yuvRange != nil { return "YUV" }
        return nil
      }
    }
    if let a = model(selected), let b = model(delivered), a != b {
      throw CaptureFidelityError.colorModelChanged(selected: a, delivered: b)
    }
    guard selected.width == delivered.width, selected.height == delivered.height else {
      throw CaptureFidelityError.dimensionsChanged(
        selected: "\(selected.width)x\(selected.height)",
        delivered: "\(delivered.width)x\(delivered.height)")
    }
    if let a = selected.bitsPerChannel, let b = delivered.bitsPerChannel, a != b {
      throw CaptureFidelityError.bitDepthChanged(selected: a, delivered: b)
    }
    if let a = selected.chromaSampling, let b = delivered.chromaSampling, a != b {
      throw CaptureFidelityError.chromaChanged(selected: a.rawValue, delivered: b.rawValue)
    }
    if let a = selected.yuvRange, let b = delivered.yuvRange, a != b {
      throw CaptureFidelityError.rangeChanged(selected: a.rawValue, delivered: b.rawValue)
    }
    if let a = selected.chromaLocation, let b = delivered.chromaLocation, a != b {
      throw CaptureFidelityError.chromaLocationChanged(selected: a.rawValue, delivered: b.rawValue)
    }
    let exact =
      selected.fourCC == delivered.fourCC && selected.bitsPerChannel == delivered.bitsPerChannel
      && (selected.chromaSampling == nil || selected.chromaSampling == delivered.chromaSampling)
      && (selected.yuvRange == nil || selected.yuvRange == delivered.yuvRange)
    // MJPG, jpeg and dmb1 are recognized spellings for the same native JPEG
    // coding-data path. A spelling change is not a decoded-pixel conversion;
    // FrameExtraction still validates and retains the complete JPEG payload.
    let equivalentJPEG = selectedFamily == .nativeJPEG && deliveredFamily == .nativeJPEG
    let representationPreserved = exact || equivalentJPEG
    let conversion =
      representationPreserved
      ? []
      : [
        "Selected \(CaptureFormat.fourCCString(selected.fourCC)); macOS delivered \(CaptureFormat.fourCCString(delivered.fourCC))."
      ]
    let verifiedNative = representationPreserved && upstreamNoConversionEstablished
    return AcquisitionEvidence(
      deviceUniqueID: deviceUniqueID, generation: generation,
      selectedFormat: selected, deliveredFormat: delivered,
      fidelity: verifiedNative
        ? .nativePreserved
        : (representationPreserved ? .macDeliveredUnknownUpstream : .macDeliveredConverted),
      knownConversions: conversion)
  }
}

/// The shutter's typed decision. This is shared by the application and the
/// headless acceptance runner so readiness and acquisition evidence cannot be
/// reduced to a freshness-only Boolean in either path.
public enum CaptureEligibilityDecision: Hashable, Sendable {
  case rejectedFormat
  case staleFrame
  case waitingForReadiness(ReadinessState)
  case eligible

  public static func evaluate(
    isFresh: Bool,
    readiness: ReadinessState,
    formatIsValid: Bool,
    adjustingOverride: Bool = false
  ) -> Self {
    guard formatIsValid else { return .rejectedFormat }
    guard isFresh else { return .staleFrame }
    switch readiness {
    case .ready:
      break
    case .stillAdjusting where adjustingOverride:
      break
    default:
      return .waitingForReadiness(readiness)
    }
    return .eligible
  }
}

/// Configuration-scoped shutter state shared by the app and acceptance
/// runner. Changing the selected mode or delivered representation revokes
/// any adjustment override. Unknown upstream provenance is recorded but does
/// not require an acknowledgment before capture.
public struct CaptureEligibilityState: Hashable, Sendable {
  public private(set) var configurationKey: String?
  private var adjustingOverride = false

  public init() {}

  public mutating func selectConfiguration(_ key: String?) {
    guard key != configurationKey else { return }
    configurationKey = key
    adjustingOverride = false
  }

  public mutating func allowWhileAdjusting(_ readiness: ReadinessState) {
    guard case .stillAdjusting = readiness else { return }
    adjustingOverride = true
  }

  public func decision(
    configurationKey: String?, isFresh: Bool, readiness: ReadinessState,
    formatIsValid: Bool
  ) -> CaptureEligibilityDecision {
    let matches = configurationKey != nil && self.configurationKey == configurationKey
    guard matches else { return .staleFrame }
    return CaptureEligibilityDecision.evaluate(
      isFresh: isFresh, readiness: readiness, formatIsValid: formatIsValid,
      adjustingOverride: matches && adjustingOverride)
  }
}
