// Per-format rate discovery without qualified CMIO property reads.

import AVFoundation
import CoreMedia
import PixelBoothCore

/// Thread-confined format reference and its advertised supported rates.
/// Only the resulting CameraMode values cross actor boundaries.
public struct FormatFrameRateCapabilities {
  public let formatDescription: CMFormatDescription
  public let ranges: [SupportedFrameRateRange]

  public init(formatDescription: CMFormatDescription, ranges: [SupportedFrameRateRange]) {
    self.formatDescription = formatDescription
    self.ranges = ranges.filter {
      $0.minimum.isFinite && $0.maximum.isFinite && $0.minimum > 0
        && $0.maximum >= $0.minimum
    }
  }

  public init(format: AVCaptureDevice.Format) {
    self.init(
      formatDescription: format.formatDescription,
      ranges: format.videoSupportedFrameRateRanges.map {
        SupportedFrameRateRange(minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
      })
  }

  /// Current CMIO capabilities take precedence for an exactly equal format.
  /// Otherwise require one exact AVFoundation match; geometry/FourCC alone
  /// cannot distinguish representations with different advertised rates.
  public static func matching(
    _ description: CMFormatDescription, current: Self?, advertised: [Self]
  ) -> Self? {
    if let current, !current.ranges.isEmpty,
      CMFormatDescriptionEqual(description, otherFormatDescription: current.formatDescription)
    {
      return current
    }
    let matches = advertised.filter {
      CMFormatDescriptionEqual(description, otherFormatDescription: $0.formatDescription)
    }
    guard matches.count == 1, !matches[0].ranges.isEmpty else { return nil }
    return matches[0]
  }

  /// Refresh a CMIO mode without changing its stable selection identity.
  public func updating(_ mode: CameraMode) -> CameraMode {
    guard mode.formatID == CMIOCaptureDiscovery.formatIdentity(formatDescription),
      let minimum = ranges.map(\.minimum).min(), let maximum = ranges.map(\.maximum).max()
    else { return mode }
    var updated = mode
    updated.minFrameRate = minimum
    updated.maxFrameRate = maximum
    return updated
  }
}
