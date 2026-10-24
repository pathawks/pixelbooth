// Metadata suite: Exif construction, XMP provenance, and AVIF metadata
// round-trip. The encoder's verifier compares Exif and XMP byte-exactly, so
// a malformed Exif payload or a dropped XMP fails the encode.

import Foundation
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCore
import PixelBoothMetadata

func runMetadataExifSuite() async {
  suite("MetadataExif")

  await test("ExifBuilder.producesLittleEndianTIFFWithCameraIdentity") {
    let exif = ExifBuilder.build(
      make: "Apple Inc.", model: "FaceTime HD Camera", software: "PixelBooth 0.1.0",
      captureISO: "2026-09-24T03:26:15Z")
    // TIFF header: "II", magic 42 little-endian, IFD0 at offset 8.
    guard exif.count >= 8, exif[0] == 0x49, exif[1] == 0x49,
      exif[2] == 0x2A, exif[3] == 0x00, exif[4] == 8
    else {
      throw exifTestError("TIFF header malformed")
    }
    for expected in ["Apple Inc.", "FaceTime HD Camera", "PixelBooth 0.1.0"] {
      guard exifTextContains(exif, expected) else {
        throw exifTestError("missing text: \(expected)")
      }
    }
    guard exifTextContains(exif, "2026:") else {
      throw exifTestError("DateTime not present")
    }
  }

  await test("ExifBuilder.entriesAreAscendingAndAligned") {
    let exif = ExifBuilder.build(
      make: "Apple Inc.", model: "FaceTime HD Camera", software: "PixelBooth 0.1.0",
      captureISO: "2026-09-24T03:26:15.123Z")
    guard exif.count >= 10 else { throw exifTestError("payload too small") }
    // IFD0 at 8: entry count, then 12-byte entries with ascending tags.
    let entryCount = Int(exif[8]) | (Int(exif[9]) << 8)
    guard entryCount >= 5 else { throw exifTestError("IFD0 entries \(entryCount) < 5") }
    var previousTag = 0
    for i in 0..<entryCount {
      let base = 10 + i * 12
      guard base + 12 <= exif.count else { throw exifTestError("IFD0 truncated") }
      let tag = Int(exif[base]) | (Int(exif[base + 1]) << 8)
      guard tag > previousTag else { throw exifTestError("tags not ascending at entry \(i)") }
      previousTag = tag
    }
  }

  await test("ExifBuilder.omitsPlaceholderTextTags") {
    let placeholders: [String?] = [
      nil, "", " \t\n", "Unknown", " UNKNOWN \n", "unavailable", "Not Available",
      "Not Applicable", "N/A", "none", "null", "unspecified", "undefined",
    ]
    for placeholder in placeholders {
      let exif = ExifBuilder.build(
        make: placeholder, model: placeholder, software: placeholder,
        captureISO: "2026-09-24T03:26:15Z")
      let tags = try exifIFD0Tags(exif)
      guard tags.isDisjoint(with: [0x010F, 0x0110, 0x0131]),
        tags.contains(0x0132), tags.contains(0x8769)
      else { throw exifTestError("placeholder text tag written or capture time lost") }
    }
  }

  await test("ExifBuilder.omitsUnknownMakeButRetainsKnownModelAndSoftware") {
    let exif = ExifBuilder.build(
      make: "Unknown", model: "Logitech BRIO", software: "PixelBooth 0.1.0",
      captureISO: "2026-09-24T03:26:15Z")
    let tags = try exifIFD0Tags(exif)
    guard !tags.contains(0x010F), tags.contains(0x0110), tags.contains(0x0131),
      exifTextContains(exif, "Logitech BRIO"), exifTextContains(exif, "PixelBooth 0.1.0")
    else { throw exifTestError("unknown make retained or known identity lost") }
  }

  await test("ExifBuilder.preservesMeaningfulTextContainingPlaceholderWords") {
    let make = " Unknown Camera Company "
    let model = "N/A-100"
    let software = "UnknownTools 1.0"
    let exif = ExifBuilder.build(
      make: make, model: model, software: software,
      captureISO: "2026-09-24T03:26:15Z")
    let tags = try exifIFD0Tags(exif)
    guard tags.isSuperset(of: [0x010F, 0x0110, 0x0131]),
      [make, model, software].allSatisfy({ exifTextContains(exif, $0) })
    else { throw exifTestError("meaningful text was omitted or changed") }
  }

  await test("ExifBuilder.rejectsUnparseableTime") {
    let exif = ExifBuilder.build(
      make: "Apple", model: "Camera", software: "PixelBooth", captureISO: "not-a-time")
    guard exif.isEmpty else { throw exifTestError("payload built from unparseable time") }
  }

  await test("ExifBuilder.retainsCaptureTimeOffsetAndSubseconds") {
    let exif = ExifBuilder.build(
      make: nil, model: nil, software: "PixelBooth",
      captureISO: "2026-09-21T23:40:51.987-07:00")
    guard exifTextContains(exif, "2026:09:21 23:40:51"),
      exifTextContains(exif, "-07:00"), exifTextContains(exif, "987")
    else { throw exifTestError("capture wall time, offset, or subsecond was lost") }
  }

  await test("ExifBuilder.writesStandardsBasedGPSIFD") {
    let location = HostLocationObservation(
      latitude: -33.8688, longitude: 151.2093, altitude: -15.5,
      horizontalAccuracy: 4.25, verticalAccuracy: 8,
      timestampISO: "2026-09-24T03:26:15.250Z", ageAtCaptureSeconds: 2)
    let exif = ExifBuilder.build(
      make: nil, model: nil, software: "PixelBooth",
      captureISO: "2026-09-24T03:26:15.250Z", location: location)

    func u16(_ offset: Int) -> Int {
      Int(exif[offset]) | (Int(exif[offset + 1]) << 8)
    }
    func u32(_ offset: Int) -> Int {
      Int(exif[offset]) | (Int(exif[offset + 1]) << 8)
        | (Int(exif[offset + 2]) << 16) | (Int(exif[offset + 3]) << 24)
    }
    func entry(_ ifdOffset: Int, _ tag: Int) -> Int? {
      let count = u16(ifdOffset)
      for index in 0..<count {
        let candidate = ifdOffset + 2 + index * 12
        if u16(candidate) == tag { return candidate }
      }
      return nil
    }

    guard let gpsPointer = entry(8, 0x8825) else { throw exifTestError("GPS IFD pointer missing") }
    let gpsOffset = u32(gpsPointer + 8)
    guard gpsOffset > 0, let latitudeRef = entry(gpsOffset, 0x0001),
      let latitude = entry(gpsOffset, 0x0002),
      let longitudeRef = entry(gpsOffset, 0x0003),
      let longitude = entry(gpsOffset, 0x0004),
      let altitudeRef = entry(gpsOffset, 0x0005),
      let altitude = entry(gpsOffset, 0x0006),
      let timestamp = entry(gpsOffset, 0x0007),
      let accuracy = entry(gpsOffset, 0x001F)
    else {
      throw exifTestError("GPS IFD fields missing")
    }
    guard exif[latitudeRef + 8] == 0x53,
      exif[longitudeRef + 8] == 0x45,
      exif[altitudeRef + 8] == 1
    else {
      throw exifTestError("GPS references have incorrect hemispheres/altitude sign")
    }
    let latitudeData = u32(latitude + 8)
    let longitudeData = u32(longitude + 8)
    let altitudeData = u32(altitude + 8)
    let timeData = u32(timestamp + 8)
    let accuracyData = u32(accuracy + 8)
    guard latitudeData > 0, longitudeData > 0, altitudeData > 0,
      timeData > 0, accuracyData > 0,
      u32(latitudeData) / u32(latitudeData + 4) == 33,
      u32(longitudeData) / u32(longitudeData + 4) == 151
    else {
      throw exifTestError("GPS rational values or offsets are malformed")
    }
  }

  await test("AVIF.exifAndXMPRoundTripByteExact") {
    let width = 16
    let height = 16
    let y = [UInt8](repeating: 0x80, count: width * height)
    let u = [UInt8](repeating: 128, count: (width / 2) * (height / 2))
    let v = [UInt8](repeating: 0x80, count: (width / 2) * (height / 2))
    let exif = ExifBuilder.build(
      make: "Apple Inc.", model: "FaceTime HD Camera", software: "PixelBooth test",
      captureISO: "2026-09-24T03:26:15Z")
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(), appVersion: "0.1.0", captureBackend: "test", backendVersion: "v",
      libavifVersion: LosslessAVIF.libraryVersion, actualCaptureFormat: "420v 16×16",
      encoderSettings: "test",
      metadataProvenance: [
        MetadataObservation(
          key: "DeviceMake", rawValueString: "Apple Inc.", provenance: .hostObserved),
        MetadataObservation(
          key: "ExifMakeModelMirroredFromHostObservedDeviceIdentity",
          rawValueString: "true", provenance: .applicationGenerated),
      ],
      fidelity: "nativePreserved", hostLocation: nil,
      mediaTimeNanos: 1, wallClockAnchorISO: "2026-09-24T03:26:15Z")
    try y.withUnsafeBytes { yBytes in
      try u.withUnsafeBytes { uBytes in
        try v.withUnsafeBytes { vBytes in
          _ = try LosslessAVIF.encodeLossless(
            PlanarImage(
              width: width, height: height, bitsPerChannel: 8,
              planes: [yBytes.baseAddress!, uBytes.baseAddress!, vBytes.baseAddress!],
              bytesPerRow: [width, width / 2, width / 2],
              rowCount: [height, height / 2, height / 2],
              bytesPerSample: 1, chromaWidth: width / 2, chromaHeight: height / 2, ownedStorage: []),
            isRGBIdentity: false, yuvRange: .full, chromaLocation: nil,
            colorPrimaries: 1, transferCharacteristics: 13, matrixCoefficients: 1,
            exifPayload: exif, xmpPayload: xmp)
        }
      }
    }
  }

  await test("AVIF.withoutMetadataHasNone") {
    let width = 8
    let height = 8
    let y = [UInt8](repeating: 0x7F, count: width * height)
    let u = [UInt8](repeating: 0x80, count: (width / 2) * (height / 2))
    let v = [UInt8](repeating: 0x80, count: (width / 2) * (height / 2))
    try y.withUnsafeBytes { yBytes in
      try u.withUnsafeBytes { uBytes in
        try v.withUnsafeBytes { vBytes in
          _ = try LosslessAVIF.encodeLossless(
            PlanarImage(
              width: width, height: height, bitsPerChannel: 8,
              planes: [yBytes.baseAddress!, uBytes.baseAddress!, vBytes.baseAddress!],
              bytesPerRow: [width, width / 2, width / 2],
              rowCount: [height, height / 2, height / 2],
              bytesPerSample: 1, chromaWidth: width / 2, chromaHeight: height / 2, ownedStorage: []),
            isRGBIdentity: false, yuvRange: .limited, chromaLocation: nil,
            colorPrimaries: 1, transferCharacteristics: 13, matrixCoefficients: 1)
        }
      }
    }
  }
}

private enum ExifMetadataError: Error { case setup(String) }
private func exifTestError(_ message: String) -> ExifMetadataError { .setup(message) }

private func exifIFD0Tags(_ payload: [UInt8]) throws -> Set<UInt16> {
  guard payload.count >= 10 else { throw exifTestError("IFD0 missing") }
  let count = Int(payload[8]) | (Int(payload[9]) << 8)
  guard payload.count >= 10 + count * 12 + 4 else { throw exifTestError("IFD0 truncated") }
  return Set(
    (0..<count).map { index in
      let offset = 10 + index * 12
      return UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    })
}

/// Case-sensitive substring search over the raw payload bytes.
private func exifTextContains(_ payload: [UInt8], _ needle: String) -> Bool {
  let hay = payload
  let chars = Array(needle.utf8)
  guard !chars.isEmpty, hay.count >= chars.count else { return false }
  for start in 0...(hay.count - chars.count) {
    var matched = true
    for (offset, byte) in chars.enumerated() where hay[start + offset] != byte {
      matched = false
      break
    }
    if matched { return true }
  }
  return false
}
