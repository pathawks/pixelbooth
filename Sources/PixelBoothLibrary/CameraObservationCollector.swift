// PixelBoothMetadata — camera-provided values from frame/sample attachments.
//
// These values are observed by the host from macOS-delivered buffers; they are
// labeled cameraProvided when they appear to originate from the camera, but the
// host cannot prove they describe the saved frame without camera documentation.
// They are preserved separately from host-observed or application-generated data.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothMetadata

/// Extracts camera-provided numeric and string values from sample-buffer and
/// pixel-buffer attachments. Only public/supported attachment access is used.
public enum CameraObservationCollector {
  /// Keys whose values map to standard Exif fields. Values are accepted only
  /// when finite and positive (or nonnegative for 35-mm-equivalent focal
  /// length); the original observation is preserved separately.
  public static let exifMappableKeys: [String: String] = [
    "FNumber": "ExifFNumber",
    "Fnumber": "ExifFNumber",
    "FocalLength": "ExifFocalLength",
    "FocalLengthIn35mmFilm": "ExifFocalLengthIn35mmFilm",
    "FocalLenIn35mmFilm": "ExifFocalLengthIn35mmFilm",
  ]

  /// Read all retrievable camera-provided values from a delivered frame.
  public static func collect(from frame: DeliveredFrame) -> [MetadataObservation] {
    var values: [String: Any] = [:]
    let sample = frame.sourceSampleBuffer ?? frame.sampleBuffer
    for mode in [CMAttachmentMode(1), CMAttachmentMode(0)] {
      let attachments =
        CMCopyDictionaryOfAttachments(
          allocator: nil, target: sample, attachmentMode: mode) as? [String: Any] ?? [:]
      merge(attachments, into: &values)
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[String: Any]]
    {
      for dict in attachments {
        merge(dict, into: &values)
      }
    }
    if let pb = CMSampleBufferGetImageBuffer(sample) {
      for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
        let attachments = CVBufferCopyAttachments(pb, mode) as? [String: Any] ?? [:]
        merge(attachments, into: &values)
      }
    }
    var observations: [MetadataObservation] = []
    for key in values.keys.sorted() {
      let value = values[key]!
      guard let normalized = normalizedValue(value) else { continue }
      observations.append(
        MetadataObservation(
          key: exifMappableKeys[key] ?? key,
          rawValueString: normalized,
          provenance: .cameraProvided))
    }
    return observations
  }

  /// Typed camera-provided values for generated Exif. Returns the value and
  /// the original string observation when available.
  public static func exifValues(
    from observations: [MetadataObservation]
  ) -> (
    fNumber: (value: Double, raw: String)?,
    focalLength: (value: Double, raw: String)?,
    focalLengthIn35mmFilm: (value: Double, raw: String)?
  ) {
    var fNumber: (Double, String)?
    var focalLength: (Double, String)?
    var focalLengthIn35mmFilm: (Double, String)?
    for obs in observations where obs.provenance == .cameraProvided {
      switch obs.key {
      case "ExifFNumber":
        if let v = Double(obs.rawValueString), v.isFinite, v > 0 {
          fNumber = (v, obs.rawValueString)
        }
      case "ExifFocalLength":
        if let v = Double(obs.rawValueString), v.isFinite, v > 0 {
          focalLength = (v, obs.rawValueString)
        }
      case "ExifFocalLengthIn35mmFilm":
        if let v = Double(obs.rawValueString), v.isFinite, v >= 0 {
          focalLengthIn35mmFilm = (v, obs.rawValueString)
        }
      default:
        break
      }
    }
    return (fNumber, focalLength, focalLengthIn35mmFilm)
  }

  private static func normalizedValue(_ value: Any) -> String? {
    switch value {
    case let number as NSNumber:
      if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      let d = number.doubleValue
      guard d.isFinite else { return nil }
      // Double(Int.max) rounds up to 2^63 on 64-bit systems. Keep the upper
      // bound exclusive so converting that NSNumber cannot trap.
      if d == d.rounded(), d >= Double(Int.min), d < -Double(Int.min) {
        return String(Int(d))
      }
      return String(d)
    case let string as String:
      guard !string.isEmpty else { return nil }
      return string
    default:
      return nil
    }
  }

  private static func collectOpticalValues(
    from dictionary: [String: Any], into values: inout [String: Any]
  ) {
    for key in dictionary.keys.sorted() {
      guard let value = dictionary[key] else { continue }
      if isNestedScalarObservationKey(key), normalizedValue(value) != nil {
        values[key] = value
      } else if let nested = value as? [String: Any] {
        collectOpticalValues(from: nested, into: &values)
      }
    }
  }

  /// Attachment sources are merged in a stable order: sample propagating,
  /// sample nonpropagating, sample-entry dictionaries, then pixel propagating
  /// and nonpropagating. Later observations deterministically take precedence
  /// for duplicate keys, matching the flat attachment merge behavior.
  private static func merge(_ attachments: [String: Any], into values: inout [String: Any]) {
    for key in attachments.keys.sorted() where !key.isEmpty {
      values[key] = attachments[key]
    }
    if let metadata = attachments["MetadataDictionary"] as? [String: Any] {
      collectOpticalValues(from: metadata, into: &values)
    }
  }

  private static func isNestedScalarObservationKey(_ key: String) -> Bool {
    exifMappableKeys[key] != nil
      || ["ExposureTime", "WhiteBalance"].contains {
        $0.caseInsensitiveCompare(key) == .orderedSame
      }
  }
}
