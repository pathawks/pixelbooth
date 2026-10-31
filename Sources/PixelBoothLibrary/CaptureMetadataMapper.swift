// PixelBoothLibrary — combines camera-provided frame attachments and host-observed
// UVC control state into Exif-mappable values and application-XMP observations.

import Foundation
import PixelBoothCore
import PixelBoothMetadata

/// Typed metadata values derived from all available sources for a captured frame.
public struct CaptureMetadataMapping {
  public var fNumber: (value: Double, source: Source, raw: String)?
  public var focalLength: (value: Double, source: Source, raw: String)?
  public var focalLengthIn35mmFilm: (value: Double, source: Source, raw: String)?
  public var exposureTimeSeconds: (value: Double, source: Source, raw: String)?
  public var exposureMode: (value: UInt16, source: Source, raw: String)?
  public var whiteBalance: (value: UInt16, source: Source, raw: String)?
  public var bodySerialNumber: (value: String, source: Source)?

  public init() {}

  public enum Source: String {
    case cameraAttachment
    case uvcControl
    case usbIdentity
  }
}

public enum CaptureMetadataMapper {
  public static func map(
    cameraObservations: [MetadataObservation],
    uvcControls: UVCControlSnapshot?,
    usbSerialNumber: String?
  ) -> CaptureMetadataMapping {
    var mapping = CaptureMetadataMapping()
    let frame = CameraObservationCollector.exifValues(from: cameraObservations)

    mapping.fNumber = frame.fNumber.map {
      (value: $0.value, source: .cameraAttachment, raw: $0.raw)
    }
    mapping.focalLength = frame.focalLength.map {
      (value: $0.value, source: .cameraAttachment, raw: $0.raw)
    }
    mapping.focalLengthIn35mmFilm = frame.focalLengthIn35mmFilm.map {
      (value: $0.value, source: .cameraAttachment, raw: $0.raw)
    }

    // Exposure time from frame attachments (seconds).
    for obs in cameraObservations where obs.provenance == .cameraProvided {
      if obs.key.caseInsensitiveCompare("ExposureTime") == .orderedSame,
        let seconds = Double(obs.rawValueString), seconds.isFinite, seconds > 0
      {
        mapping.exposureTimeSeconds = (
          value: seconds, source: .cameraAttachment,
          raw: obs.rawValueString
        )
        break
      }
    }

    // White balance from frame attachments.
    for obs in cameraObservations where obs.provenance == .cameraProvided {
      if obs.key.caseInsensitiveCompare("WhiteBalance") == .orderedSame {
        if obs.rawValueString == "0"
          || obs.rawValueString.caseInsensitiveCompare("Auto") == .orderedSame
        {
          mapping.whiteBalance = (value: 0, source: .cameraAttachment, raw: obs.rawValueString)
        } else if obs.rawValueString == "1"
          || obs.rawValueString.caseInsensitiveCompare("Manual") == .orderedSame
        {
          mapping.whiteBalance = (value: 1, source: .cameraAttachment, raw: obs.rawValueString)
        }
        break
      }
    }

    // UVC control fallback values.
    if let uvc = uvcControls {
      if mapping.fNumber == nil, let iris = uvc.irisAbsolute, iris > 0 {
        let f = Double(iris) / 100.0
        mapping.fNumber = (value: f, source: .uvcControl, raw: String(iris))
      }
      if mapping.exposureTimeSeconds == nil, let time100us = uvc.exposureTime100us {
        let seconds = Double(time100us) / 10_000.0
        mapping.exposureTimeSeconds = (
          value: seconds, source: .uvcControl, raw: String(time100us)
        )
      }
      if mapping.whiteBalance == nil, let auto = uvc.whiteBalanceAuto {
        mapping.whiteBalance = (
          value: auto ? 0 : 1, source: .uvcControl,
          raw: auto ? "auto" : "manual"
        )
      }
      if mapping.exposureMode == nil, let mode = uvc.exposureMode,
        let exifMode = mode.exifExposureMode()
      {
        mapping.exposureMode = (
          value: exifMode, source: .uvcControl, raw: String(mode.rawValue)
        )
      }
    }

    if let serial = usbSerialNumber {
      mapping.bodySerialNumber = (value: serial, source: .usbIdentity)
    }

    return mapping
  }

  /// UVC values as application-XMP observations, preserving raw values and units.
  public static func uvcObservations(_ snapshot: UVCControlSnapshot?) -> [MetadataObservation] {
    guard let snapshot else { return [] }
    var observations: [MetadataObservation] = []
    func add(_ key: String, _ value: Any?, _ units: String? = nil) {
      guard let value else { return }
      var raw = String(describing: value)
      if let units { raw += " \(units)" }
      observations.append(
        MetadataObservation(
          key: key, rawValueString: raw, provenance: .hostObserved,
          observedAtISO: snapshot.observedAtISO))
    }
    add("UVCExposureTime", snapshot.exposureTime100us, "100us")
    if let mode = snapshot.exposureMode {
      add("UVCExposureMode", mode.rawValue)
    }
    add("UVCWhiteBalanceAuto", snapshot.whiteBalanceAuto)
    add("UVCWhiteBalanceTemperature", snapshot.whiteBalanceTemperature, "K")
    add("UVCFocusAuto", snapshot.focusAuto)
    add("UVCFocusAbsolute", snapshot.focusAbsoluteMm, "mm")
    add("UVCIrisAbsolute", snapshot.irisAbsolute, "1/100 FNumber")
    add("UVCGain", snapshot.gain)
    add("UVCContrast", snapshot.contrast)
    add("UVCSaturation", snapshot.saturation)
    add("UVCSharpness", snapshot.sharpness)
    add("UVCGamma", snapshot.gamma)
    add("UVCBacklightCompensation", snapshot.backlightCompensation)
    for issue in snapshot.issues {
      observations.append(
        MetadataObservation(
          key: "UVCControlIssue", rawValueString: issue, provenance: .applicationGenerated))
    }
    return observations
  }
}
