// CaptureDiscovery — AVFoundation device discovery and identity enrichment.
// Camera identity comes from supported APIs only; unavailable fields are
// reported as unavailable. Optional identity enrichment is isolated from
// frame acquisition.

import AVFoundation
import CoreAudio
import Foundation
import PixelBoothCore

/// An enumerated camera with the identity information we could actually read.
public struct CameraDevice: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case builtIn, external, other
  }

  public var uniqueID: String
  public var localizedName: String
  public var modelID: String?
  public var manufacturer: String?
  public var deviceConnected: Bool
  public var usbIdentity: USBDeviceIdentity?
  /// Device type and transport are acquisition API observations, independent
  /// of optional USB descriptor enrichment.
  public var kind: Kind
  public var transportType: UInt32?

  public var isExternalUSB: Bool {
    kind == .external && transportType == UInt32(kAudioDeviceTransportTypeUSB)
  }

  public var id: String { uniqueID }

  public init(
    uniqueID: String, localizedName: String,
    modelID: String? = nil, manufacturer: String? = nil,
    deviceConnected: Bool = true, usbIdentity: USBDeviceIdentity? = nil,
    kind: Kind = .other, transportType: UInt32? = nil
  ) {
    self.uniqueID = uniqueID
    self.localizedName = localizedName
    self.modelID = modelID
    self.manufacturer = manufacturer
    self.deviceConnected = deviceConnected
    self.usbIdentity = usbIdentity
    self.kind = kind
    self.transportType = transportType
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
    let usbRecords = USBIdentityDiscovery.records()
    return discovery.devices.map { dev in
      CameraDevice(
        uniqueID: dev.uniqueID,
        localizedName: dev.localizedName,
        modelID: dev.modelID,
        manufacturer: dev.manufacturer,
        deviceConnected: dev.isConnected,
        usbIdentity: USBDeviceIdentity.matching(
          deviceUID: dev.uniqueID,
          isUSBTransport: UInt32(bitPattern: dev.transportType)
            == UInt32(kAudioDeviceTransportTypeUSB),
          records: usbRecords),
        kind: dev.deviceType == .builtInWideAngleCamera
          ? .builtIn
          : dev.deviceType == .external ? .external : .other,
        transportType: UInt32(bitPattern: dev.transportType))
    }
  }

  public func enumerateModes(for device: AVCaptureDevice) -> [CameraMode] {
    Self.advertisedModes(for: device)
  }

  /// Stable AVFoundation format identities and understood representation facts.
  public static func advertisedModes(
    for device: AVCaptureDevice, formats: [AVCaptureDevice.Format]? = nil
  ) -> [CameraMode] {
    (formats ?? device.formats).enumerated().map { index, format in
      let description = format.formatDescription
      let dimensions = CMVideoFormatDescriptionGetDimensions(description)
      let fourCC = CMFormatDescriptionGetMediaSubType(description)
      let ranges = format.videoSupportedFrameRateRanges
      let minimum = ranges.map { 1.0 / $0.maxFrameDuration.seconds }.min() ?? 0
      let maximum = ranges.map { 1.0 / $0.minFrameDuration.seconds }.max() ?? 0
      let facts = CaptureFormatFacts.applying(
        to: CaptureFormat(
          width: Int(dimensions.width), height: Int(dimensions.height), fourCC: fourCC))
      return CameraMode(
        deviceID: device.uniqueID, formatID: String(index), mediaSubType: fourCC,
        dimensions: (Int(dimensions.width), Int(dimensions.height)),
        minFrameRate: minimum, maxFrameRate: maximum, pixelFormat: fourCC,
        bitsPerChannel: facts.bitsPerChannel, chromaSampling: facts.chromaSampling,
        yuvRange: facts.yuvRange)
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
