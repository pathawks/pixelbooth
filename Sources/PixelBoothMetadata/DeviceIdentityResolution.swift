import Foundation
import PixelBoothCore

public struct DeviceIdentityResolution: Hashable, Sendable, Codable {
  public enum Source: String, Hashable, Sendable, Codable {
    case avfoundation
    case usbDescriptor
    case usbIDLookup

    public var provenance: MetadataProvenance {
      self == .usbIDLookup ? .applicationGenerated : .hostObserved
    }
  }

  public var manufacturer: String?
  public var manufacturerSource: Source?
  public var model: String?
  public var modelSource: Source?

  /// A deliberately small USB-ID map, independent of camera display names.
  /// Source: usb-ids.gowdy.us/read/UD/046d (checked 2026-10-23).
  private static let vendors: [UInt16: String] = [0x046D: "Logitech"]
  private static let products: [UInt32: String] = [0x046D_085E: "BRIO Ultra HD Webcam"]

  public static func resolve(
    manufacturer: String?, model: String?, usb: USBDeviceIdentity?
  ) -> Self {
    let make = firstAvailable([
      (manufacturer, .avfoundation), (usb?.manufacturer, .usbDescriptor),
      (usb.flatMap { vendors[$0.vendorID] }, .usbIDLookup),
    ])
    let name = firstAvailable([
      (model, .avfoundation), (usb?.productName, .usbDescriptor),
      (usb.flatMap { products[UInt32($0.vendorID) << 16 | UInt32($0.productID)] }, .usbIDLookup),
    ])
    return Self(
      manufacturer: make?.0, manufacturerSource: make?.1, model: name?.0, modelSource: name?.1)
  }

  private static func firstAvailable(_ candidates: [(String?, Source)]) -> (String, Source)? {
    for (candidate, source) in candidates {
      if let value = ExifBuilder.meaningfulText(candidate) { return (value, source) }
    }
    return nil
  }
}
