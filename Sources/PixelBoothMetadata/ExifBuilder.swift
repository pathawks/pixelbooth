// ExifBuilder — constructs a minimal, standards-compliant Exif (TIFF) payload.
//
// The values written here are HOST-OBSERVED facts, not camera-provided Exif.
// GPS tags use the normal Exif GPS IFD so photo software can read geotags;
// application XMP separately records that the coordinates came from the Mac.

import Foundation

public enum ExifBuilder {
  struct Entry {
    let tag: UInt16
    /// TIFF field type (2 = ASCII, 4 = LONG, 5 = RATIONAL, 1 = BYTE).
    let type: UInt16
    let count: UInt32
    /// Inline bytes when ≤ 4; otherwise a reference into the data region.
    let payload: [UInt8]

    static func ascii(tag: UInt16, value: String) -> Entry {
      let bytes = Array(value.utf8)
      return Entry(tag: tag, type: 2, count: UInt32(bytes.count + 1), payload: bytes + [0])
    }

  }

  /// Little-endian TIFF ("II"): IFD0, Exif sub-IFD, optional GPS IFD, then
  /// referenced values. Source Exif is never rewritten by this builder.
  public static func build(
    make: String?, model: String?, software: String?,
    captureISO: String,
    location: HostLocationObservation? = nil
  ) -> [UInt8] {
    guard let dateTime = exifDateTime(from: captureISO) else { return [] }

    var ifd0: [Entry] = []
    if let make = meaningfulText(make) { ifd0.append(.ascii(tag: 0x010F, value: make)) }
    if let model = meaningfulText(model) { ifd0.append(.ascii(tag: 0x0110, value: model)) }
    if let software = meaningfulText(software) { ifd0.append(.ascii(tag: 0x0131, value: software)) }
    ifd0.append(.ascii(tag: 0x0132, value: dateTime))

    var exifIFD = [
      Entry.ascii(tag: 0x9003, value: dateTime),
      Entry.ascii(tag: 0x9004, value: dateTime),
    ]
    if let offset = capturedOffset(captureISO) {
      exifIFD.append(contentsOf: [
        .ascii(tag: 0x9010, value: offset),
        .ascii(tag: 0x9011, value: offset),
        .ascii(tag: 0x9012, value: offset),
      ])
    }
    if let subsecond = capturedSubsecond(captureISO) {
      exifIFD.append(contentsOf: [
        .ascii(tag: 0x9290, value: subsecond),
        .ascii(tag: 0x9291, value: subsecond),
        .ascii(tag: 0x9292, value: subsecond),
      ])
    }
    exifIFD.sort { $0.tag < $1.tag }
    let gpsIFD = location.flatMap(gpsEntries) ?? []
    ifd0.append(Entry(tag: 0x8769, type: 4, count: 1, payload: []))
    if !gpsIFD.isEmpty {
      ifd0.append(Entry(tag: 0x8825, type: 4, count: 1, payload: []))
    }
    ifd0.sort { $0.tag < $1.tag }

    let ifd0Offset = 8
    let ifd0Size = ifdSize(ifd0.count)
    let exifOffset = ifd0Offset + ifd0Size
    let exifSize = ifdSize(exifIFD.count)
    let gpsOffset = exifOffset + exifSize
    let gpsSize = gpsIFD.isEmpty ? 0 : ifdSize(gpsIFD.count)
    var dataOffset = gpsOffset + gpsSize

    var valueOffsets: [UInt16: UInt32] = [:]
    for entry in ifd0 + exifIFD + gpsIFD where entry.payload.count > 4 {
      guard let offset = UInt32(exactly: dataOffset) else { return [] }
      valueOffsets[entry.tag] = offset
      let paddedCount = entry.payload.count + (entry.payload.count % 2)
      let (next, overflow) = dataOffset.addingReportingOverflow(paddedCount)
      guard !overflow else { return [] }
      dataOffset = next
    }
    guard let exifOffset32 = UInt32(exactly: exifOffset),
      gpsIFD.isEmpty || UInt32(exactly: gpsOffset) != nil
    else { return [] }

    func serializeIFD(_ entries: [Entry], nextIFD: UInt32 = 0) -> [UInt8] {
      var bytes: [UInt8] = []
      append16(UInt16(entries.count), to: &bytes)
      for entry in entries {
        append16(entry.tag, to: &bytes)
        append16(entry.type, to: &bytes)
        append32(entry.count, to: &bytes)
        if entry.tag == 0x8769 {
          append32(exifOffset32, to: &bytes)
        } else if entry.tag == 0x8825, let gpsOffset32 = UInt32(exactly: gpsOffset) {
          append32(gpsOffset32, to: &bytes)
        } else if let offset = valueOffsets[entry.tag], entry.payload.count > 4 {
          append32(offset, to: &bytes)
        } else {
          bytes.append(contentsOf: entry.payload)
          bytes.append(contentsOf: repeatElement(0, count: 4 - entry.payload.count))
        }
      }
      append32(nextIFD, to: &bytes)
      return bytes
    }

    var out: [UInt8] = [0x49, 0x49]
    append16(42, to: &out)
    append32(UInt32(ifd0Offset), to: &out)
    out.append(contentsOf: serializeIFD(ifd0))
    out.append(contentsOf: serializeIFD(exifIFD))
    if !gpsIFD.isEmpty { out.append(contentsOf: serializeIFD(gpsIFD)) }
    for entry in ifd0 + exifIFD + gpsIFD where entry.payload.count > 4 {
      out.append(contentsOf: entry.payload)
      if entry.payload.count % 2 != 0 { out.append(0) }
    }
    return out
  }

  /// Omit whole-value placeholders from generated Exif. Preserve the exact
  /// spelling and spacing of meaningful values; raw host observations remain
  /// available separately in the capture snapshot and application XMP.
  static func meaningfulText(_ value: String?) -> String? {
    guard let value else { return nil }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "", "unknown", "unavailable", "not available", "not applicable", "n/a",
      "none", "null", "unspecified", "undefined":
      return nil
    default:
      return value
    }
  }

  private static func gpsEntries(_ location: HostLocationObservation) -> [Entry]? {
    guard location.latitude.isFinite, location.longitude.isFinite,
      (-90...90).contains(location.latitude), (-180...180).contains(location.longitude),
      !(location.latitude == 0 && location.longitude == 0),
      location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
      let timestamp = parseISO(location.timestampISO)
    else { return nil }

    var entries: [Entry] = [
      Entry(tag: 0x0000, type: 1, count: 4, payload: [2, 3, 0, 0]),
      .ascii(tag: 0x0001, value: location.latitude < 0 ? "S" : "N"),
      Entry(tag: 0x0002, type: 5, count: 3, payload: coordinateRationals(location.latitude)),
      .ascii(tag: 0x0003, value: location.longitude < 0 ? "W" : "E"),
      Entry(tag: 0x0004, type: 5, count: 3, payload: coordinateRationals(location.longitude)),
      .ascii(tag: 0x001D, value: gpsDateStamp(timestamp)),
      Entry(tag: 0x0007, type: 5, count: 3, payload: gpsTimeRationals(timestamp)),
    ]

    if let altitude = location.altitude, altitude.isFinite, altitude >= -10000,
      let altitudeNumerator = scaledUInt32(abs(altitude), scale: 1000)
    {
      entries.append(Entry(tag: 0x0005, type: 1, count: 1, payload: [altitude < 0 ? 1 : 0]))
      entries.append(
        Entry(
          tag: 0x0006, type: 5, count: 1,
          payload: rationalBytes(altitudeNumerator, 1000)))
    }
    if let accuracy = scaledUInt32(location.horizontalAccuracy, scale: 1000) {
      entries.append(
        Entry(
          tag: 0x001F, type: 5, count: 1,
          payload: rationalBytes(accuracy, 1000)))
    }
    return entries.sorted { $0.tag < $1.tag }
  }

  /// GPS coordinates are stored as degrees, minutes, and seconds rationals.
  private static func coordinateRationals(_ coordinate: Double) -> [UInt8] {
    let absolute = abs(coordinate)
    var degrees = Int(floor(absolute))
    let minuteValue = (absolute - Double(degrees)) * 60
    var minutes = Int(floor(minuteValue))
    var scaledSeconds = Int((((minuteValue - Double(minutes)) * 60) * 1_000_000).rounded())
    if scaledSeconds >= 60_000_000 {
      scaledSeconds = 0
      minutes += 1
      if minutes == 60 {
        minutes = 0
        degrees += 1
      }
    }
    return rationalBytes(UInt32(degrees), 1)
      + rationalBytes(UInt32(minutes), 1)
      + rationalBytes(UInt32(scaledSeconds), 1_000_000)
  }

  private static func gpsTimeRationals(_ date: Date) -> [UInt8] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    let seconds =
      UInt32(max(0, parts.second ?? 0)) * 1000
      + UInt32(max(0, parts.nanosecond ?? 0) / 1_000_000)
    return rationalBytes(UInt32(parts.hour ?? 0), 1)
      + rationalBytes(UInt32(parts.minute ?? 0), 1)
      + rationalBytes(seconds, 1000)
  }

  private static func gpsDateStamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private static func rationalBytes(_ numerator: UInt32, _ denominator: UInt32) -> [UInt8] {
    var bytes: [UInt8] = []
    append32(numerator, to: &bytes)
    append32(denominator, to: &bytes)
    return bytes
  }

  private static func scaledUInt32(_ value: Double, scale: Double) -> UInt32? {
    guard value.isFinite, value >= 0 else { return nil }
    let scaled = (value * scale).rounded()
    guard scaled <= Double(UInt32.max) else { return nil }
    return UInt32(scaled)
  }

  private static func ifdSize(_ entryCount: Int) -> Int { 2 + entryCount * 12 + 4 }

  private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0xff))
    bytes.append(UInt8(value >> 8))
  }

  private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0xff))
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8((value >> 16) & 0xff))
    bytes.append(UInt8(value >> 24))
  }

  private static func parseISO(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }

  /// Exif DateTime text ("yyyy:MM:dd HH:mm:ss", local time) from the capture
  /// wall-clock anchor.
  static func exifDateTime(from iso: String) -> String? {
    guard let date = parseISO(iso) else { return nil }
    let out = DateFormatter()
    out.locale = Locale(identifier: "en_US_POSIX")
    out.dateFormat = "yyyy:MM:dd HH:mm:ss"
    out.timeZone = capturedTimeZone(iso)
    return out.string(from: date)
  }

  private static func timeSuffix(in iso: String) -> (clock: String, suffix: String?)? {
    guard let separator = iso.firstIndex(of: "T") else { return nil }
    let clock = String(iso[iso.index(after: separator)...])
    if clock.hasSuffix("Z") { return (String(clock.dropLast()), "Z") }
    if let zoneStart = clock.firstIndex(where: { $0 == "+" || $0 == "-" }) {
      return (String(clock[..<zoneStart]), String(clock[zoneStart...]))
    }
    return (clock, nil)
  }

  private static func capturedOffset(_ iso: String) -> String? {
    guard let suffix = timeSuffix(in: iso)?.suffix else { return nil }
    if suffix == "Z" { return "+00:00" }
    let sign = suffix.first
    let digits = suffix.dropFirst().filter(\.isNumber)
    guard digits.count == 4,
      let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
      hours <= 23, minutes <= 59, sign == "+" || sign == "-"
    else { return nil }
    return "\(sign!)\(String(digits.prefix(2))):\(String(digits.suffix(2)))"
  }

  private static func capturedTimeZone(_ iso: String) -> TimeZone {
    guard let offset = capturedOffset(iso) else { return TimeZone(secondsFromGMT: 0)! }
    let sign = offset.first == "-" ? -1 : 1
    let digits = offset.dropFirst().filter(\.isNumber)
    let seconds = (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * sign
    return TimeZone(secondsFromGMT: seconds)!
  }

  private static func capturedSubsecond(_ iso: String) -> String? {
    guard let clock = timeSuffix(in: iso)?.clock,
      let decimal = clock.firstIndex(of: ".")
    else { return nil }
    let digits = clock[clock.index(after: decimal)...].prefix(while: \.isNumber)
    return digits.isEmpty ? nil : String(digits)
  }
}
