// PixelBoothCapture — small, self-contained UVC control reader.
//
// Reads selected Camera Terminal and Processing Unit controls directly from
// the USB device using public IOKit APIs. No dependency on CameraController.
// Failures are captured as issues; the shutter never waits on control reads.

import Foundation
import IOKit
import IOKit.usb
import PixelBoothCore

/// Reads UVC control state from a USB camera. The reader is stateless; each
/// read opens the device, issues requests, and closes it.
public enum UVCControlReader {
  /// Read controls for the USB device identified by the host observation.
  /// Returns a snapshot with any issues recorded; the caller never blocks on
  /// a thrown error.
  public static func read(identity: USBDeviceIdentity) -> UVCControlSnapshot {
    var snapshot = UVCControlSnapshot()
    snapshot.observedAtISO = ISO8601DateFormatter().string(from: Date())

    guard let service = findDeviceService(identity: identity) else {
      snapshot.issues.append("USB device service not found")
      return snapshot
    }
    defer { IOObjectRelease(service) }

    guard let device = createDeviceInterface(service: service) else {
      snapshot.issues.append("Could not create USB device interface")
      return snapshot
    }
    defer { releaseDeviceInterface(device) }

    let openResult = callDevice(device) { selfPtr, dev in
      dev.pointee.USBDeviceOpen(selfPtr)
    }
    guard openResult == kIOReturnSuccess else {
      snapshot.issues.append("Could not open USB device (IOKit error \(openResult))")
      return snapshot
    }
    defer {
      _ = callDevice(device) { selfPtr, dev in
        dev.pointee.USBDeviceClose(selfPtr)
      }
    }

    let configuration = activeConfiguration(device: device)
    guard let descriptor = configurationDescriptor(device: device, configuration: configuration)
    else {
      snapshot.issues.append("Could not read active USB configuration descriptor")
      return snapshot
    }

    let context = parseUVCDescriptors(descriptor)
    guard let vcInterface = context.vcInterfaceNumber else {
      snapshot.issues.append("No VideoControl interface found")
      return snapshot
    }
    if context.cameraTerminalID == nil {
      snapshot.issues.append("No Camera Terminal found")
    }
    if context.processingUnitID == nil {
      snapshot.issues.append("No Processing Unit found")
    }

    // Camera Terminal controls.
    if let ct = context.cameraTerminalID {
      if let raw = readControl(
        device: device, interface: vcInterface, unit: ct,
        selector: CameraTerminalSelector.exposureTimeAbsolute.rawValue, length: 4)
      {
        snapshot.exposureTime100us = raw
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: ct,
        selector: CameraTerminalSelector.aeMode.rawValue, length: 1)
      {
        snapshot.exposureMode = UVCExposureMode(rawValue: UInt8(raw & 0xFF))
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: ct,
        selector: CameraTerminalSelector.irisAbsolute.rawValue, length: 2)
      {
        snapshot.irisAbsolute = UInt32(raw & 0xFFFF)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: ct,
        selector: CameraTerminalSelector.focusAbsolute.rawValue, length: 2)
      {
        snapshot.focusAbsoluteMm = UInt32(raw & 0xFFFF)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: ct,
        selector: CameraTerminalSelector.focusAuto.rawValue, length: 1)
      {
        snapshot.focusAuto = (raw & 0xFF) != 0
      }
    }

    // Processing Unit controls.
    if let pu = context.processingUnitID {
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.whiteBalanceTemperatureAuto.rawValue, length: 1)
      {
        snapshot.whiteBalanceAuto = (raw & 0xFF) != 0
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.whiteBalanceTemperature.rawValue, length: 2)
      {
        snapshot.whiteBalanceTemperature = UInt32(raw & 0xFFFF)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.gain.rawValue, length: 2)
      {
        snapshot.gain = signed16(raw)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.contrast.rawValue, length: 2)
      {
        snapshot.contrast = signed16(raw)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.saturation.rawValue, length: 2)
      {
        snapshot.saturation = signed16(raw)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.sharpness.rawValue, length: 2)
      {
        snapshot.sharpness = signed16(raw)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.gamma.rawValue, length: 2)
      {
        snapshot.gamma = signed16(raw)
      }
      if let raw = readControl(
        device: device, interface: vcInterface, unit: pu,
        selector: ProcessingUnitSelector.backlightCompensation.rawValue, length: 2)
      {
        snapshot.backlightCompensation = signed16(raw)
      }
    }

    return snapshot
  }

  // MARK: - Private helpers

  private enum CameraTerminalSelector: UInt8 {
    case scanningMode = 0x01
    case aeMode = 0x02
    case aePriority = 0x03
    case exposureTimeAbsolute = 0x04
    case focusAbsolute = 0x06
    case focusAuto = 0x08
    case irisAbsolute = 0x09
  }

  private enum ProcessingUnitSelector: UInt8 {
    case backlightCompensation = 0x01
    case contrast = 0x03
    case gain = 0x04
    case saturation = 0x07
    case sharpness = 0x08
    case gamma = 0x09
    case whiteBalanceTemperature = 0x0A
    case whiteBalanceTemperatureAuto = 0x0B
  }

  private struct UVCDescriptorContext {
    var vcInterfaceNumber: UInt8?
    var cameraTerminalID: UInt8?
    var processingUnitID: UInt8?
  }

  /// Calls a device vtable function with the correct double-pointer `self`.
  private static func callDevice(
    _ device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?,
    _ body: (UnsafeMutableRawPointer, UnsafeMutablePointer<IOUSBDeviceInterface>) -> IOReturn?
  ) -> IOReturn {
    guard let device, let interface = device.pointee else { return kIOReturnError }
    return body(UnsafeMutableRawPointer(device), interface) ?? kIOReturnError
  }

  private static func activeConfiguration(
    device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
  ) -> UInt8 {
    var config: UInt8 = 0
    let result = callDevice(device) { selfPtr, dev in
      dev.pointee.GetConfiguration(selfPtr, &config)
    }
    guard result == kIOReturnSuccess else { return 0 }
    return config
  }

  private static func signed16(_ raw: UInt32) -> Int32 {
    Int32(bitPattern: UInt32(raw & 0xFFFF))
  }

  private static func findDeviceService(identity: USBDeviceIdentity) -> io_service_t? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
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
        let location = properties["locationID"] as? NSNumber
      else { continue }
      if UInt16(exactly: vendor.uint64Value) == identity.vendorID,
        UInt16(exactly: product.uint64Value) == identity.productID,
        UInt32(exactly: location.uint64Value) == identity.locationID
      {
        // Transfer ownership to the caller.
        _ = IOObjectRetain(service)
        return service
      }
    }
    return nil
  }

  private static func createDeviceInterface(
    service: io_service_t
  ) -> UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>? {
    // IOKit UUID constants are C macros and are not imported into Swift.
    // They are recreated here locally to avoid non-Sendable global state.
    let usbDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
      kCFAllocatorDefault,
      0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
      0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    let iocfPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
      kCFAllocatorDefault,
      0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
      0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    let usbDeviceInterfaceID942 = CFUUIDGetConstantUUIDWithBytes(
      kCFAllocatorDefault,
      0x56, 0xAD, 0x08, 0x9D, 0x87, 0x8D, 0x4B, 0xEA,
      0xA1, 0xF5, 0x2C, 0x8D, 0xC4, 0x3E, 0x8A, 0x98)

    var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard
      IOCreatePlugInInterfaceForService(
        service, usbDeviceUserClientTypeID, iocfPlugInInterfaceID,
        &pluginInterface, &score) == kIOReturnSuccess,
      let pluginPtr = pluginInterface,
      let plugin = pluginPtr.pointee
    else { return nil }
    defer {
      // IODestroyPlugInInterface owns the plug-in teardown. Calling the
      // interface's Release first would release the same COM object twice.
      IODestroyPlugInInterface(pluginPtr)
    }

    var rawInterface: UnsafeMutableRawPointer?
    let queryResult = withUnsafeMutablePointer(to: &rawInterface) { ptr in
      plugin.pointee.QueryInterface(
        UnsafeMutableRawPointer(pluginPtr),
        CFUUIDGetUUIDBytes(usbDeviceInterfaceID942),
        ptr)
    }
    guard queryResult == kIOReturnSuccess, let rawInterface else { return nil }
    return rawInterface.assumingMemoryBound(
      to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
  }

  private static func releaseDeviceInterface(
    _ device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
  ) {
    guard let device, let interface = device.pointee else { return }
    _ = interface.pointee.Release(UnsafeMutableRawPointer(device))
  }

  private static func configurationDescriptor(
    device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?,
    configuration: UInt8
  ) -> Data? {
    // Configuration values are typically 1-based while descriptor indices are
    // 0-based. Try the inferred index first, then fall back to index 0.
    let candidates: [UInt8] = configuration > 0 ? [configuration - 1, 0] : [0]
    for index in candidates {
      var descriptorPtr: UnsafeMutablePointer<IOUSBConfigurationDescriptor>?
      let result = callDevice(device) { selfPtr, dev in
        dev.pointee.GetConfigurationDescriptorPtr(selfPtr, index, &descriptorPtr)
      }
      if result == kIOReturnSuccess, let rawDescriptor = descriptorPtr {
        // wTotalLength includes the configuration descriptor itself.
        let length = Int(rawDescriptor.pointee.wTotalLength)
        guard length >= MemoryLayout<IOUSBConfigurationDescriptor>.size else {
          continue
        }
        return Data(bytes: rawDescriptor, count: length)
      }
    }
    return nil
  }

  private static func parseUVCDescriptors(_ descriptor: Data) -> UVCDescriptorContext {
    var context = UVCDescriptorContext()
    var offset = 0
    var currentInterfaceNumber: UInt8?
    var currentInterfaceClass: UInt8?
    var currentInterfaceSubClass: UInt8?

    while offset + 2 <= descriptor.count {
      let length = Int(descriptor[offset])
      let type = descriptor[offset + 1]
      guard length >= 2, offset + length <= descriptor.count else { break }

      if type == kUSBInterfaceDesc, length >= 9 {
        currentInterfaceNumber = descriptor[offset + 2]
        currentInterfaceClass = descriptor[offset + 5]
        currentInterfaceSubClass = descriptor[offset + 6]
        if currentInterfaceClass == 0x0E, currentInterfaceSubClass == 0x01,
          context.vcInterfaceNumber == nil
        {
          context.vcInterfaceNumber = currentInterfaceNumber
        }
      } else if type == 0x24, length >= 3 {
        // Class-specific interface descriptor.
        let subtype = descriptor[offset + 2]
        if subtype == 0x02, length >= 15,
          let interface = currentInterfaceNumber,
          interface == context.vcInterfaceNumber
        {
          // Camera Terminal descriptor.
          context.cameraTerminalID = descriptor[offset + 3]
        } else if subtype == 0x05, length >= 10,
          let interface = currentInterfaceNumber,
          interface == context.vcInterfaceNumber
        {
          // Processing Unit descriptor.
          context.processingUnitID = descriptor[offset + 3]
        }
      }

      offset += length
    }
    return context
  }

  private static func readControl(
    device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?,
    interface: UInt8,
    unit: UInt8,
    selector: UInt8,
    length: Int
  ) -> UInt32? {
    var value: UInt32 = 0
    let result = callDevice(device) { selfPtr, dev in
      withUnsafeMutablePointer(to: &value) { pointer in
        var request = IOUSBDevRequest(
          bmRequestType: 0xA1,  // IN, CLASS, INTERFACE
          bRequest: 0x81,  // GET_CUR
          wValue: UInt16(selector) << 8,
          wIndex: (UInt16(unit) << 8) | UInt16(interface),
          wLength: UInt16(length),
          pData: UnsafeMutableRawPointer(pointer),
          wLenDone: 0)
        return dev.pointee.DeviceRequest(selfPtr, &request)
      }
    }
    guard result == kIOReturnSuccess else { return nil }
    return value
  }
}
