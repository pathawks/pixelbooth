import Foundation
import IOKit
import PixelBoothCore

enum USBIdentityDiscovery {
  /// Registry reads only: no USB device opens, control requests, or stream changes.
  static func records() -> [USBDeviceIdentity] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    let observed = ISO8601DateFormatter().string(from: Date())
    var result: [USBDeviceIdentity] = []
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      defer { IOObjectRelease(service) }
      var reference: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(service, &reference, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let properties = reference?.takeRetainedValue() as? [String: Any],
        let vendor = properties["idVendor"] as? NSNumber,
        let product = properties["idProduct"] as? NSNumber,
        let location = properties["locationID"] as? NSNumber,
        let vendorID = UInt16(exactly: vendor.uint64Value),
        let productID = UInt16(exactly: product.uint64Value),
        let locationID = UInt32(exactly: location.uint64Value)
      else { continue }
      result.append(
        USBDeviceIdentity(
          vendorID: vendorID, productID: productID, locationID: locationID,
          manufacturer: properties["USB Vendor Name"] as? String,
          productName: properties["USB Product Name"] as? String, observedAtISO: observed))
    }
    return result
  }
}
