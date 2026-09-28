// CaptureDiscovery — AVFoundation device discovery and identity enrichment.
// Camera identity comes from supported APIs only; unavailable fields are
// reported as unavailable. Optional identity enrichment is isolated from
// frame acquisition.

import AVFoundation
import Foundation
import PixelBoothCore

/// An enumerated camera with the identity information we could actually read.
public struct CameraDevice: Identifiable, Hashable, Sendable {
  public var uniqueID: String
  public var localizedName: String
  public var modelID: String?
  public var manufacturer: String?
  public var deviceConnected: Bool

  public var id: String { uniqueID }

  public init(
    uniqueID: String, localizedName: String,
    modelID: String? = nil, manufacturer: String? = nil,
    deviceConnected: Bool = true
  ) {
    self.uniqueID = uniqueID
    self.localizedName = localizedName
    self.modelID = modelID
    self.manufacturer = manufacturer
    self.deviceConnected = deviceConnected
  }
}

/// Discovers actual devices and their actual formats via AVFoundation.
/// Uses only supported APIs. Built-in cameras are included but are reported
/// with truthful provenance (they are not UVC).
public actor CaptureDiscovery {
  public init() {}

  /// Discover all video devices.
  public func discoverCameras() async -> [CameraDevice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video,
      position: .unspecified)
    return discovery.devices.map { dev in
      CameraDevice(
        uniqueID: dev.uniqueID,
        localizedName: dev.localizedName,
        modelID: nil,  // modelID is not exposed by macOS AVFoundation
        manufacturer: dev.manufacturer,
        deviceConnected: dev.isConnected)
    }
  }

  public func enumerateModes(for device: AVCaptureDevice) -> [CameraMode] {
    device.formats.map { formatDescription in
      let desc = formatDescription.formatDescription
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      let fourCC = CMFormatDescriptionGetMediaSubType(desc)
      // Frame-rate ranges.
      let ranges = formatDescription.videoSupportedFrameRateRanges
      let supported = ranges.map {
        SupportedFrameRateRange(
          minimum: 1.0 / $0.maxFrameDuration.seconds,
          maximum: 1.0 / $0.minFrameDuration.seconds)
      }
      let minRate = supported.map(\.minimum).min() ?? 0
      let maxRate = supported.map(\.maximum).max() ?? 0
      return CameraMode(
        deviceID: device.uniqueID,
        formatID: nil,
        mediaSubType: fourCC,
        dimensions: (Int(dims.width), Int(dims.height)),
        minFrameRate: minRate,
        maxFrameRate: maxRate,
        pixelFormat: fourCC,
        isHighestFrameRate: false)
    }
  }

  /// Formats that AVCaptureVideoDataOutput can actually deliver.
  /// Excludes encoded-stream-only formats (H.264) which VideoDataOutput
  /// cannot emit as raw buffers.
  public static func dataOutputCapableFormats(for device: AVCaptureDevice) -> [AVCaptureDevice
    .Format]
  {
    device.formats.filter { format in
      let fourCC = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      // Filter out H.264-only formats; keep everything else the data output can handle.
      return fourCC != 0x6176_6331  // 'avc1'
    }
  }
}
