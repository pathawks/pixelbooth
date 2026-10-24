import Foundation

/// USB identity read from IORegistry. Association describes the checked match,
/// not a guarantee that every AVFoundation device has a USB counterpart.
public struct USBDeviceIdentity: Hashable, Sendable, Codable {
  public var vendorID: UInt16
  public var productID: UInt16
  public var locationID: UInt32
  public var manufacturer: String?
  public var productName: String?
  public var observedAtISO: String?
  public var associationMethod: String?

  public init(
    vendorID: UInt16, productID: UInt16, locationID: UInt32,
    manufacturer: String? = nil, productName: String? = nil,
    observedAtISO: String? = nil, associationMethod: String? = nil
  ) {
    self.vendorID = vendorID
    self.productID = productID
    self.locationID = locationID
    self.manufacturer = manufacturer
    self.productName = productName
    self.observedAtISO = observedAtISO
    self.associationMethod = associationMethod
  }

  /// macOS UVC convention: locationID << 32 | vendorID << 16 | productID.
  /// Require all fields to match one registry entry; never match by camera name.
  public static func matching(
    deviceUID: String, isUSBTransport: Bool, records: [Self]
  ) -> Self? {
    guard isUSBTransport, deviceUID.hasPrefix("0x"), deviceUID.count <= 18,
      deviceUID.dropFirst(2).allSatisfy(\.isHexDigit),
      let identifier = UInt64(deviceUID.dropFirst(2), radix: 16)
    else { return nil }
    let location = UInt32(identifier >> 32)
    guard location != 0 else { return nil }
    let vendor = UInt16(truncatingIfNeeded: identifier >> 16)
    let product = UInt16(truncatingIfNeeded: identifier)
    let matches = records.filter {
      $0.locationID == location && $0.vendorID == vendor && $0.productID == product
    }
    guard matches.count == 1 else { return nil }
    var matched = matches[0]
    matched.associationMethod = "macOS-UVC-composite-UID+IORegistry-location-VID-PID"
    return matched
  }
}
