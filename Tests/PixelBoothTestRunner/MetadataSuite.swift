// Metadata tests: versioned XMP namespace, provenance separation, and the
// location acceptance policy (invalid/stale/zero/altitude rejection).

import Foundation
import PixelBoothAVIF
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata

private enum MetadataTestError: Error { case setup(String) }
private func metadataTestError(_ message: String) -> MetadataTestError { .setup(message) }

func runMetadataSuite() async {
  suite("Metadata")

  await test("legacyCaptureJSONDecodesWithoutNewMetadataFields") {
    let capture = CapturedCapture.makeTestCapture(
      fourCC: 0x4e56_3132, width: 4, height: 2,
      payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
    let encoded = try JSONEncoder().encode(capture)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var metadata = object["metadata"] as? [String: Any]
    else { throw metadataTestError("test capture JSON shape changed") }
    for key in [
      "cameraObservations", "hostObservedDeviceModelID", "captureBackend",
      "captureBackendVersion", "includeEstimatedDisparity", "attachmentArchive",
      "colorEncodingFailure", "usbIdentity", "deviceIdentity", "streamColorObservations",
      "deviceMetadata", "frameDurationSeconds", "deliveredPixelFormat", "videoRange",
      "warmupFrames", "uvcControls",
    ] {
      metadata.removeValue(forKey: key)
    }
    object["metadata"] = metadata
    let legacyJSON = try JSONSerialization.data(withJSONObject: object)
    let recovered = try JSONDecoder().decode(CapturedCapture.self, from: legacyJSON)
    guard recovered.metadata.cameraObservations.isEmpty,
      recovered.metadata.mediaTimeNanos == capture.metadata.mediaTimeNanos,
      recovered.width == capture.width, recovered.height == capture.height
    else { throw metadataTestError("legacy staged capture did not recover intact") }
  }

  await test("XMPLabelsVersionedProvenance") {
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      appVersion: "0.1.0",
      captureBackend: "AVFoundation",
      backendVersion: "macOS 27.0",
      libavifVersion: LosslessAVIF.libraryVersion,
      actualCaptureFormat: "NV12 8-bit 4:2:0 limited",
      encoderSettings: "codec=aom quality=lossless speed=0",
      metadataProvenance: [
        MetadataObservation(key: "exposure", rawValueString: "1/60", provenance: .cameraProvided),
        MetadataObservation(
          key: "gain", rawValueString: "4", provenance: .hostObserved,
          observedAtISO: "2026-09-21T12:00:00.000Z"),
      ],
      fidelity: "nativePreserved",
      hostLocation: nil,
      mediaTimeNanos: 12345,
      wallClockAnchorISO: "2026-09-21T12:00:00.000Z")
    let text = String(bytes: xmp, encoding: .utf8) ?? ""
    check(
      text.contains("CaptureUUID=\"11111111-2222-3333-4444-555555555555\""), "UUID present")
    check(text.contains("AcquisitionFidelity=\"nativePreserved\""), "fidelity present")
    check(text.contains("cameraProvided"), "camera provenance labeled")
    check(text.contains("hostObserved"), "host provenance labeled")
    check(text.contains("SchemaVersion=\"1\""), "schema versioned")
  }

  await test("XMPIncludesHostLocationAndStandardGeotags") {
    let loc = HostLocationObservation(
      latitude: 47.6062, longitude: -122.3321, altitude: 40,
      horizontalAccuracy: 10, verticalAccuracy: 5,
      timestampISO: "2026-09-21T12:00:00.000Z", ageAtCaptureSeconds: 3)
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(), appVersion: "0.1.0",
      captureBackend: "AVFoundation", backendVersion: "macOS 27.0",
      libavifVersion: LosslessAVIF.libraryVersion,
      actualCaptureFormat: "NV12", encoderSettings: "x",
      metadataProvenance: [], fidelity: "nativePreserved",
      hostLocation: loc, mediaTimeNanos: 1, wallClockAnchorISO: "t")
    let text = String(bytes: xmp, encoding: .utf8) ?? ""
    check(text.contains("HostLatitude=\"47.6062\""), "latitude recorded")
    check(text.contains("HostHorizontalAccuracy=\"10.0\""), "accuracy recorded")
    check(text.contains("HostVerticalAccuracy=\"5.0\""), "vertical accuracy recorded")
    check(text.contains("HostLocationAgeAtCaptureSeconds=\"3.0\""), "age recorded")
    check(
      text.contains("exif:GPSLatitude=\"47,36.37200000N\""), "standard XMP latitude geotag")
    check(
      text.contains("exif:GPSLongitude=\"122,19.92600000W\""), "standard XMP longitude geotag")
  }

  await test("XMPIncludesCaptureContextFields") {
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(), appVersion: "0.1.0",
      captureBackend: "AVFoundation", backendVersion: "macOS 27.0",
      libavifVersion: LosslessAVIF.libraryVersion,
      actualCaptureFormat: "NV12", encoderSettings: "x",
      metadataProvenance: [], fidelity: "nativePreserved",
      hostLocation: nil, mediaTimeNanos: 1, wallClockAnchorISO: "t",
      creatorTool: "PixelBooth 0.1.0",
      frameDurationSeconds: 0.033333333,
      pixelFormat: "NV12",
      videoRange: "limited",
      activeEffects: ["CenterStage", "Portrait"],
      warmupFrames: 8)
    let text = String(bytes: xmp, encoding: .utf8) ?? ""
    check(text.contains("CreatorTool=\"PixelBooth 0.1.0\""), "creator tool recorded")
    check(text.contains("FrameDuration=\"0.033333333\""), "frame duration recorded")
    check(text.contains("PixelFormat=\"NV12\""), "pixel format recorded")
    check(text.contains("VideoRange=\"limited\""), "video range recorded")
    check(text.contains("ActiveEffects=\"CenterStage,Portrait\""), "active effects recorded")
    check(text.contains("WarmupFrames=\"8\""), "warmup frames recorded")
  }

  await test("CaptureMetadataMapperPrefersCameraAttachmentsOverUVC") {
    let observations = [
      MetadataObservation(
        key: "ExposureTime", rawValueString: "0.008", provenance: .cameraProvided),
      MetadataObservation(
        key: "WhiteBalance", rawValueString: "1", provenance: .cameraProvided),
      MetadataObservation(
        key: "ExifFNumber", rawValueString: "2.8", provenance: .cameraProvided),
    ]
    let uvc = UVCControlSnapshot(
      exposureTime100us: 3333, whiteBalanceAuto: true, irisAbsolute: 400)
    let mapping = CaptureMetadataMapper.map(
      cameraObservations: observations, uvcControls: uvc, usbSerialNumber: nil)
    guard let exposureTime = mapping.exposureTimeSeconds,
      abs(exposureTime.value - 0.008) < 0.0001,
      exposureTime.source == .cameraAttachment
    else { throw metadataTestError("camera exposure time not preferred") }
    guard let whiteBalance = mapping.whiteBalance,
      whiteBalance.value == 1, whiteBalance.source == .cameraAttachment
    else { throw metadataTestError("camera white balance not preferred") }
    guard let fNumber = mapping.fNumber,
      abs(fNumber.value - 2.8) < 0.001, fNumber.source == .cameraAttachment
    else { throw metadataTestError("camera FNumber not preferred") }
  }

  await test("CaptureMetadataMapperFallsBackToUVCControls") {
    let uvc = UVCControlSnapshot(
      exposureTime100us: 5000, exposureMode: .manual, whiteBalanceAuto: false,
      irisAbsolute: 280)
    let mapping = CaptureMetadataMapper.map(
      cameraObservations: [], uvcControls: uvc, usbSerialNumber: "SERIAL")
    guard let exposureTime = mapping.exposureTimeSeconds,
      abs(exposureTime.value - 0.5) < 0.001, exposureTime.source == .uvcControl
    else { throw metadataTestError("UVC exposure time not used") }
    guard let exposureMode = mapping.exposureMode,
      exposureMode.value == 1, exposureMode.source == .uvcControl
    else { throw metadataTestError("UVC exposure mode not mapped") }
    guard let whiteBalance = mapping.whiteBalance,
      whiteBalance.value == 1, whiteBalance.source == .uvcControl
    else { throw metadataTestError("UVC white balance not mapped") }
    guard let fNumber = mapping.fNumber,
      abs(fNumber.value - 2.8) < 0.001, fNumber.source == .uvcControl
    else { throw metadataTestError("UVC iris not mapped to FNumber") }
    guard let serial = mapping.bodySerialNumber,
      serial.value == "SERIAL", serial.source == .usbIdentity
    else { throw metadataTestError("USB serial not mapped") }
  }

  await test("CaptureMetadataMapperUVCExposureModesMapToExif") {
    let modes: [(UVCExposureMode, UInt16?)] = [
      (.auto, 0),
      (.manual, 1),
      (.aperturePriority, 0),
      (.shutterPriority, 0),
    ]
    for (uvcMode, expected) in modes {
      let mapping = CaptureMetadataMapper.map(
        cameraObservations: [],
        uvcControls: UVCControlSnapshot(exposureMode: uvcMode),
        usbSerialNumber: nil)
      guard mapping.exposureMode?.value == expected else {
        throw metadataTestError("UVC mode \(uvcMode.rawValue) mapped incorrectly")
      }
    }

    for priorityMode in [UVCExposureMode.aperturePriority, .shutterPriority] {
      let snapshot = UVCControlSnapshot(exposureMode: priorityMode)
      guard snapshot.exposureMode?.exifExposureMode() == 0,
        CaptureMetadataMapper.uvcObservations(snapshot).contains(where: {
          $0.key == "UVCExposureMode" && $0.rawValueString == String(priorityMode.rawValue)
        })
      else { throw metadataTestError("priority mode lost or written as invalid Exif") }
    }
  }

  await test("CaptureMetadataMapperUVCObservationsPreserveRawValues") {
    let uvc = UVCControlSnapshot(
      exposureTime100us: 10000, whiteBalanceTemperature: 5600, gain: 128,
      issues: ["focus read failed"])
    let observations = CaptureMetadataMapper.uvcObservations(uvc)
    let keys = observations.map(\.key)
    guard keys.contains("UVCExposureTime") else {
      throw metadataTestError("exposure time observation missing")
    }
    guard keys.contains("UVCWhiteBalanceTemperature") else {
      throw metadataTestError("white balance temperature observation missing")
    }
    guard keys.contains("UVCGain") else { throw metadataTestError("gain observation missing") }
    guard
      observations.contains(where: {
        $0.key == "UVCControlIssue" && $0.rawValueString == "focus read failed"
      })
    else { throw metadataTestError("UVC issue not preserved") }
    guard
      observations.allSatisfy({
        $0.provenance == .hostObserved || $0.provenance == .applicationGenerated
      })
    else { throw metadataTestError("UVC observations have wrong provenance") }
  }

  await test("CameraObservationCollectorExtractsExifMappableValues") {
    let observations = [
      MetadataObservation(
        key: "ExifFNumber", rawValueString: "2.8", provenance: .cameraProvided),
      MetadataObservation(
        key: "ExifFocalLength", rawValueString: "4.25", provenance: .cameraProvided),
      MetadataObservation(
        key: "ExifFocalLengthIn35mmFilm", rawValueString: "28.5", provenance: .cameraProvided),
      MetadataObservation(
        key: "ExifFNumber", rawValueString: "-1", provenance: .cameraProvided),
    ]
    let values = CameraObservationCollector.exifValues(from: observations)
    guard let fNumber = values.fNumber, abs(fNumber.value - 2.8) < 0.001 else {
      throw metadataTestError("FNumber not extracted")
    }
    guard let focalLength = values.focalLength, abs(focalLength.value - 4.25) < 0.001 else {
      throw metadataTestError("FocalLength not extracted")
    }
    guard let focalLength35 = values.focalLengthIn35mmFilm,
      abs(focalLength35.value - 28.5) < 0.001
    else { throw metadataTestError("FocalLengthIn35mmFilm not extracted") }
  }

  await test("locationPolicyRejectsInvalidAndStaleObservations") {
    let policy = LocationAcceptance(maximumAgeSeconds: 60)
    func obs(lat: Double, lon: Double, alt: Double?, age: Double) -> HostLocationObservation {
      HostLocationObservation(
        latitude: lat, longitude: lon, altitude: alt,
        horizontalAccuracy: 10, verticalAccuracy: nil,
        timestampISO: "2026-09-21T12:00:00.000Z",
        ageAtCaptureSeconds: age)
    }
    let captureISO = "2026-09-21T12:00:00.000Z"
    check(
      LocationAcceptance.accept(
        obs(lat: 47.6, lon: -122.3, alt: 40, age: 2), atCaptureISO: captureISO, policy: policy)
        != nil, "valid accepted")
    check(
      LocationAcceptance.accept(
        obs(lat: 0, lon: 0, alt: nil, age: 1), atCaptureISO: captureISO, policy: policy) == nil,
      "zero coords rejected")
    check(
      LocationAcceptance.accept(
        obs(lat: 47.6, lon: -122.3, alt: nil, age: 61), atCaptureISO: captureISO, policy: policy)
        == nil, "stale rejected")
    check(
      LocationAcceptance.accept(
        obs(lat: 47.6, lon: -122.3, alt: -20000, age: 1), atCaptureISO: captureISO, policy: policy)
        == nil, "invalid altitude rejected")
    check(
      LocationAcceptance.accept(
        obs(lat: 95, lon: -200, alt: nil, age: 1), atCaptureISO: captureISO, policy: policy) == nil,
      "out-of-range rejected")
    check(
      LocationAcceptance.accept(nil, atCaptureISO: captureISO, policy: policy) == nil,
      "missing observation omitted")
    var invalidAccuracy = obs(lat: 47.6, lon: -122.3, alt: nil, age: 1)
    invalidAccuracy.horizontalAccuracy = -1
    check(
      LocationAcceptance.accept(invalidAccuracy, atCaptureISO: captureISO, policy: policy) == nil,
      "invalid accuracy rejected")
    let nonFinite = obs(lat: .nan, lon: -122.3, alt: nil, age: 1)
    check(
      LocationAcceptance.accept(nonFinite, atCaptureISO: captureISO, policy: policy) == nil,
      "non-finite coordinate rejected")
  }
}
