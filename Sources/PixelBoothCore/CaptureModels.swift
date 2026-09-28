// PixelBoothCore — domain models shared across modules.
// Capture formats describe what a camera *delivers*, with honest provenance.

import Foundation

/// A camera-delivered pixel representation. FourCC + geometry + interpretation.
/// Never "sensor RAW"; this describes the macOS-delivered sample representation
/// as negotiated with the camera.
public struct CaptureFormat: Hashable, Sendable, Codable {
  public var width: Int
  public var height: Int
  /// FourCC of the delivered representation, e.g. 0x4e563132 ("NV12").
  public var fourCC: UInt32
  /// Known bits per meaningful channel sample (8/10/12). `nil` = unknown.
  public var bitsPerChannel: Int?
  /// Known chroma sampling. `nil` = unknown or not applicable (RGB/mono).
  public var chromaSampling: ChromaSampling?
  /// Known YUV range. `nil` = unknown or not applicable.
  public var yuvRange: YUVRange?
  /// Known chroma sample position. `nil` = unknown or not applicable.
  public var chromaLocation: ChromaLocation?
  /// Whether the representation carries meaningful alpha (not padding).
  public var hasAlpha: Bool
  /// Maximum frame rate the mode advertises, in frames per second.
  public var maxFrameRate: Double

  public enum ChromaSampling: String, Hashable, Sendable, Codable {
    case yuv420, yuv422, yuv444, monochrome
  }

  public enum YUVRange: String, Hashable, Sendable, Codable {
    case full, limited
  }

  public enum ChromaLocation: String, Hashable, Sendable, Codable {
    case left, center, topLeft, top, topRight, bottomLeft, bottom, bottomRight
  }

  public init(width: Int, height: Int, fourCC: UInt32,
              bitsPerChannel: Int? = nil, chromaSampling: ChromaSampling? = nil,
              yuvRange: YUVRange? = nil, chromaLocation: ChromaLocation? = nil,
              hasAlpha: Bool = false, maxFrameRate: Double = 30) {
    self.width = width
    self.height = height
    self.fourCC = fourCC
    self.bitsPerChannel = bitsPerChannel
    self.chromaSampling = chromaSampling
    self.yuvRange = yuvRange
    self.chromaLocation = chromaLocation
    self.hasAlpha = hasAlpha
    self.maxFrameRate = maxFrameRate
  }
}

/// High-level codec family of a mode. Drives the archival pipeline.
public enum CaptureCodecFamily: String, Hashable, Sendable, Codable {
  case nativeJPEG       // MJPEG stream: full JPEG passthrough path
  case uncompressedRGB  // RGB/BGR/BGRA/BGRAP and friends
  case uncompressedYUV  // YUY2/UYVY/NV12/420v/420f/444f/Y210 etc.
  case h264             // H.264 encoded stream; decoded via VideoToolbox
  case unknown
}

/// Acquisition-fidelity classification of a selected camera/format combination.
/// This is honest, evidence-driven; it is never presented as "sensor RAW".
public enum AcquisitionFidelity: Hashable, Sendable, Codable {
  /// Camera and AVFoundation both deliver the native representation: we have
  /// evidence (matching format FourCC plus a non-empty, confirmed-delivery
  /// videoSettings dictionary) that no conversion occurred upstream of us.
  case nativePreserved
  /// We know macOS performed a conversion (delivered format ≠ camera format).
  /// The delivered representation is still preserved exactly after macOS.
  case macDeliveredConverted
  /// Upstream behavior could not be established. Requires explicit user
  /// acknowledgment before use; never silently substituted for native.
  case macDeliveredUnknownUpstream
}

/// Where the image-coding data originates, for provenance reporting.
public enum DataSource: Hashable, Sendable, Codable {
  case cameraNative        // e.g. MJPEG payload straight from camera
  case macDecoded          // e.g. H.264 decoded via VideoToolbox
  case macDelivered        // uncompressed YUV/RGB as macOS handed it to us
  case unknown
}

/// Descriptive label for a representation, per the product spec: dimensions,
/// codec/FourCC, known bit depth and chroma sampling; unknown shown honestly.
extension CaptureFormat {
  public static func fourCCString(_ v: UInt32) -> String {
    let bytes = [
      UInt8(truncatingIfNeeded: v >> 24),
      UInt8(truncatingIfNeeded: v >> 16),
      UInt8(truncatingIfNeeded: v >> 8),
      UInt8(truncatingIfNeeded: v),
    ]
    return bytes.map { b -> String in
      let printable = 0x21...0x7e
      return printable.contains(Int(b)) ? String(UnicodeScalar(b)) : "?"
    }.joined()
  }

  public var descriptiveLabel: String {
    var parts = ["\(width)×\(height)", CaptureFormat.fourCCString(fourCC)]
    if let bits = bitsPerChannel {
      parts.append("\(bits)-bit")
    } else {
      parts.append("unknown depth")
    }
    if let cs = chromaSampling {
      parts.append(cs.rawValue.uppercased())
    } else if yuvRange != nil || chromaLocation != nil {
      parts.append("unknown chroma")
    }
    parts.append(String(format: "%.1f fps max", maxFrameRate))
    return parts.joined(separator: " · ")
  }
}

/// Codec family classification from a delivered FourCC. Only what we can
/// honestly know from the FourCC plus optionally-reported format description.
public extension CaptureFormat {
  var codecFamily: CaptureCodecFamily {
    switch fourCC {
    case 0x4d4a5047: return .nativeJPEG       // "MJPG"
    case 0x61766331: return .h264             // "avc1"
    case 0x42475241, 0x52474241: return .uncompressedRGB  // "BGRA", "RGBA"
    default: return .uncompressedYUV          // YUY2/UYVY/NV12/420v/420f/v210 etc.
    }
  }
}

/// One negotiated camera mode, as advertised by the device.
public struct CameraMode: Sendable, Identifiable, Hashable, Equatable {
  public var deviceID: String
  public var formatID: String?
  public var mediaSubType: UInt32       // CMFormatDescription media subtype (FourCC)
  public var dimensionsWidth: Int
  public var dimensionsHeight: Int
  public var minFrameRate: Double
  public var maxFrameRate: Double
  public var pixelFormat: UInt32        // FourCC the data output delivers
  public var isHighestFrameRate: Bool
  /// Bits per channel we actually know for this mode; nil = unknown.
  public var bitsPerChannel: Int?
  /// Chroma sampling we actually know; nil = unknown or not applicable.
  public var chromaSampling: CaptureFormat.ChromaSampling?
  /// YUV range we actually know; nil = unknown or not applicable.
  public var yuvRange: CaptureFormat.YUVRange?

  public init(deviceID: String, formatID: String?, mediaSubType: UInt32,
              dimensions: (width: Int, height: Int), minFrameRate: Double,
              maxFrameRate: Double, pixelFormat: UInt32,
              isHighestFrameRate: Bool = false,
              bitsPerChannel: Int? = nil,
              chromaSampling: CaptureFormat.ChromaSampling? = nil,
              yuvRange: CaptureFormat.YUVRange? = nil) {
    self.deviceID = deviceID
    self.formatID = formatID
    self.mediaSubType = mediaSubType
    self.dimensionsWidth = dimensions.width
    self.dimensionsHeight = dimensions.height
    self.minFrameRate = minFrameRate
    self.maxFrameRate = maxFrameRate
    self.pixelFormat = pixelFormat
    self.isHighestFrameRate = isHighestFrameRate
    self.bitsPerChannel = bitsPerChannel
    self.chromaSampling = chromaSampling
    self.yuvRange = yuvRange
  }

  public var dimensions: (width: Int, height: Int) {
    (dimensionsWidth, dimensionsHeight)
  }

  public var id: String {
    "\(deviceID)#\(formatID ?? "-")#\(pixelFormat)#\(dimensions.width)x\(dimensions.height)#\(String(format: "%.2f", maxFrameRate))"
  }

  public var stableID: String { id }

  public var codecFamily: CaptureCodecFamily {
    CaptureFormat(
      width: dimensions.width, height: dimensions.height, fourCC: pixelFormat,
      bitsPerChannel: bitsPerChannel, chromaSampling: chromaSampling,
      yuvRange: yuvRange, chromaLocation: nil, hasAlpha: false,
      maxFrameRate: maxFrameRate).codecFamily
  }

  public var asCaptureFormat: CaptureFormat {
    CaptureFormat(
      width: dimensions.width, height: dimensions.height, fourCC: pixelFormat,
      bitsPerChannel: bitsPerChannel, chromaSampling: chromaSampling,
      yuvRange: yuvRange, chromaLocation: nil, hasAlpha: false,
      maxFrameRate: maxFrameRate)
  }

  /// Human-readable description including what we do/don't know.
  public var descriptiveLabel: String {
    "\(dimensions.width)×\(dimensions.height) · \(Int(maxFrameRate)) fps max · \(CaptureFormat.fourCCString(pixelFormat))"
  }
}

/// Provenance record: who provided what, with what evidence.
public struct ProvenanceRecord: Hashable, Sendable, Codable {
  public var deviceReportedFormat: CaptureFormat?
  public var deliveredFormat: CaptureFormat
  public var knownConversions: [String]
  public var fidelity: AcquisitionFidelity
  public var source: DataSource
  public var configurationGeneration: Int

  public init(deviceReportedFormat: CaptureFormat?, deliveredFormat: CaptureFormat,
              knownConversions: [String], fidelity: AcquisitionFidelity,
              source: DataSource, configurationGeneration: Int) {
    self.deviceReportedFormat = deviceReportedFormat
    self.deliveredFormat = deliveredFormat
    self.knownConversions = knownConversions
    self.fidelity = fidelity
    self.source = source
    self.configurationGeneration = configurationGeneration
  }
}

/// Readiness state machine outputs.
public enum ReadinessState: Hashable, Sendable, Codable {
  case warmingUp(framesNeeded: Int, msSinceStart: Int, adjusting: Bool)
  case ready
  case stillAdjusting(exceededMs: Int)
  case noStream
}

/// Heuristic readiness policy: configurable product defaults, not claims
/// about all cameras.
public struct ReadinessHeuristic: Hashable, Sendable, Codable {
  public var minimumFreshFrames: Int
  public var minimumMillisecondsSinceValidStart: Int
  public var maximumAdjustingWaitMilliseconds: Int

  public init(minimumFreshFrames: Int = 8,
              minimumMillisecondsSinceValidStart: Int = 500,
              maximumAdjustingWaitMilliseconds: Int = 5000) {
    self.minimumFreshFrames = minimumFreshFrames
    self.minimumMillisecondsSinceValidStart = minimumMillisecondsSinceValidStart
    self.maximumAdjustingWaitMilliseconds = maximumAdjustingWaitMilliseconds
  }

  public static let `default` = ReadinessHeuristic()
}

/// Frame tag carrying the configuration generation at capture time.
/// Used to reject frames delivered under an old configuration.
public struct FrameGenerationTag: Hashable, Sendable, Codable {
  public var generation: Int
  public var deviceUniqueID: String

  public init(generation: Int, deviceUniqueID: String) {
    self.generation = generation
    self.deviceUniqueID = deviceUniqueID
  }
}
