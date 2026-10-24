import Foundation
import PixelBoothCore
import PixelBoothMetadata

func runUSBIdentitySuite() async {
  suite("USBIdentity")

  let first = USBDeviceIdentity(
    vendorID: 0x046D, productID: 0x085E, locationID: 0x1234_0000,
    manufacturer: nil, productName: "Reported USB product", observedAtISO: "2026-10-23T12:00:00Z")
  let second = USBDeviceIdentity(
    vendorID: 0x046D, productID: 0x085E, locationID: 0x5678_0000,
    manufacturer: "USB-reported manufacturer", productName: "Another USB product")

  await test("compositeUIDMatchesLocationVendorAndProductNotNames") {
    let match = USBDeviceIdentity.matching(
      deviceUID: "0x12340000046d085e", isUSBTransport: true, records: [second, first])
    check(match?.locationID == first.locationID, "same-model devices are distinguished by location")
    check(match?.productName == first.productName, "correct registry device selected")
    check(match?.associationMethod?.contains("IORegistry") == true, "association evidence recorded")
  }

  await test("opaqueAmbiguousMismatchedAndNonUSBIdentitiesRemainUnavailable") {
    for uid in [
      "opaque-device-id", "0x12340000046d0000", "0x10000000000000000", "0x00000000046d085e",
    ] {
      check(
        USBDeviceIdentity.matching(deviceUID: uid, isUSBTransport: true, records: [first]) == nil,
        "unverified identity cannot acquire USB data")
    }
    check(
      USBDeviceIdentity.matching(
        deviceUID: "0x12340000046d085e", isUSBTransport: false, records: [first]) == nil,
      "non-USB transport is not parsed as USB")
    check(
      USBDeviceIdentity.matching(
        deviceUID: "0x12340000046d085e", isUSBTransport: true, records: [first, first]) == nil,
      "ambiguous registry matches are not selected")
  }

  await test("manufacturerPrefersAVFoundationThenUSBStringsThenIDMap") {
    let avf = DeviceIdentityResolution.resolve(
      manufacturer: "API manufacturer", model: "API model", usb: second)
    check(
      avf.manufacturer == "API manufacturer" && avf.manufacturerSource == .avfoundation,
      "AVFoundation has priority")
    let usb = DeviceIdentityResolution.resolve(
      manufacturer: "Unknown", model: "API model", usb: second)
    check(
      usb.manufacturer == second.manufacturer && usb.manufacturerSource == .usbDescriptor,
      "reported USB string has priority over numeric lookup")
    let lookup = DeviceIdentityResolution.resolve(
      manufacturer: "N/A", model: "Brio 100", usb: first)
    check(
      lookup.manufacturer == "Logitech" && lookup.manufacturerSource == .usbIDLookup,
      "vendor ID fallback works without matching the camera display name")
    check(
      lookup.manufacturerSource?.provenance == .applicationGenerated, "lookup origin is explicit")
    check(
      lookup.model == "Brio 100" && lookup.modelSource == .avfoundation, "model name stays reported"
    )
    let noUSB = DeviceIdentityResolution.resolve(
      manufacturer: "Unknown", model: "Logitech BRIO", usb: nil)
    check(noUSB.manufacturer == nil, "camera display names never imply a manufacturer")
  }

  await test("productFallbackAndUnknownIDsDoNotFabricateValues") {
    var onlyIDs = first
    onlyIDs.productName = nil
    let known = DeviceIdentityResolution.resolve(manufacturer: nil, model: nil, usb: onlyIDs)
    check(
      known.model == "BRIO Ultra HD Webcam" && known.modelSource == .usbIDLookup,
      "known vendor/product pair resolves a model")
    onlyIDs.vendorID = 0xFFFF
    let unknown = DeviceIdentityResolution.resolve(manufacturer: nil, model: nil, usb: onlyIDs)
    check(unknown.manufacturer == nil && unknown.model == nil, "unknown IDs remain unavailable")
  }

  await test("shutterSnapshotRetainsUSBIDsAndAttributionAcrossJSON") {
    var metadata = FrameMetadataSnapshot(
      mediaTimeNanos: 1, wallClockAnchorISO: "2026-10-23T12:00:00Z", generation: 1)
    metadata.hostObservedDeviceMake = "Unknown"
    metadata.usbIdentity = USBDeviceIdentity.matching(
      deviceUID: "0x12340000046d085e", isUSBTransport: true, records: [first])
    metadata.deviceIdentity = DeviceIdentityResolution.resolve(
      manufacturer: "Unknown", model: "Reported model", usb: metadata.usbIdentity)
    let restored = try JSONDecoder().decode(
      FrameMetadataSnapshot.self, from: JSONEncoder().encode(metadata))
    check(
      restored.usbIdentity == metadata.usbIdentity, "IDs, strings, time and association persist")
    check(restored.deviceIdentity == metadata.deviceIdentity, "resolved values and sources persist")
    check(restored.hostObservedDeviceMake == "Unknown", "raw API observation remains separate")
  }
}
