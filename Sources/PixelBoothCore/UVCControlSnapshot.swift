// PixelBoothCapture — UVC control values read from the USB device after stream
// start. These are host observations of USB control state, not
// per-frame camera-reported metadata. Unavailable or unsupported controls are
// omitted rather than invented.

import Foundation

/// UVC auto-exposure mode bitmap values from the Camera Terminal control.
public struct UVCExposureMode: Hashable, Sendable, Codable {
  public var rawValue: UInt8

  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let manual = UVCExposureMode(rawValue: 0x01)
  public static let auto = UVCExposureMode(rawValue: 0x02)
  public static let shutterPriority = UVCExposureMode(rawValue: 0x04)
  public static let aperturePriority = UVCExposureMode(rawValue: 0x08)

  public var isManual: Bool { rawValue & Self.manual.rawValue != 0 }
  public var isAuto: Bool { rawValue & Self.auto.rawValue != 0 }
  public var isShutterPriority: Bool { rawValue & Self.shutterPriority.rawValue != 0 }
  public var isAperturePriority: Bool { rawValue & Self.aperturePriority.rawValue != 0 }

  public func exifExposureMode() -> UInt16? {
    // Exif ExposureMode only defines 0=Auto, 1=Manual, and 2=Auto bracket.
    // UVC priority modes describe automatic exposure, so use Auto while the
    // full UVC bitmask remains available in application XMP.
    if rawValue == Self.manual.rawValue { return 1 }
    if [Self.auto.rawValue, Self.shutterPriority.rawValue, Self.aperturePriority.rawValue]
      .contains(rawValue)
    {
      return 0
    }
    return nil
  }
}

/// Host-observed UVC control state observed after stream start.
public struct UVCControlSnapshot: Hashable, Sendable, Codable {
  public var exposureTime100us: UInt32?
  public var exposureMode: UVCExposureMode?
  public var whiteBalanceAuto: Bool?
  public var whiteBalanceTemperature: UInt32?
  public var focusAuto: Bool?
  public var focusAbsoluteMm: UInt32?
  public var irisAbsolute: UInt32?
  public var gain: Int32?
  public var contrast: Int32?
  public var saturation: Int32?
  public var sharpness: Int32?
  public var gamma: Int32?
  public var backlightCompensation: Int32?
  public var issues: [String]
  public var observedAtISO: String?

  public init(
    exposureTime100us: UInt32? = nil,
    exposureMode: UVCExposureMode? = nil,
    whiteBalanceAuto: Bool? = nil,
    whiteBalanceTemperature: UInt32? = nil,
    focusAuto: Bool? = nil,
    focusAbsoluteMm: UInt32? = nil,
    irisAbsolute: UInt32? = nil,
    gain: Int32? = nil,
    contrast: Int32? = nil,
    saturation: Int32? = nil,
    sharpness: Int32? = nil,
    gamma: Int32? = nil,
    backlightCompensation: Int32? = nil,
    issues: [String] = [],
    observedAtISO: String? = nil
  ) {
    self.exposureTime100us = exposureTime100us
    self.exposureMode = exposureMode
    self.whiteBalanceAuto = whiteBalanceAuto
    self.whiteBalanceTemperature = whiteBalanceTemperature
    self.focusAuto = focusAuto
    self.focusAbsoluteMm = focusAbsoluteMm
    self.irisAbsolute = irisAbsolute
    self.gain = gain
    self.contrast = contrast
    self.saturation = saturation
    self.sharpness = sharpness
    self.gamma = gamma
    self.backlightCompensation = backlightCompensation
    self.issues = issues
    self.observedAtISO = observedAtISO
  }
}
