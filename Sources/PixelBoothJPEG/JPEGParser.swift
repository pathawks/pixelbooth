// PixelBoothJPEG — JPEG passthrough preservation.
// Extracts a complete JPEG from native MJPEG samples and preserves
// image-coding markers, tables, scan data, and entropy-coded payload
// without recompression. Metadata additions use a metadata-only path.

import Foundation

/// Errors that are recoverable — the caller can surface them and continue.
public enum JPEGError: Error, Equatable, Sendable {
  case notAJPEG
  case truncated
  case malformedSegment(marker: UInt8, offset: Int)
  case metadataInsertionFailed(String)
}

/// A parsed JPEG segment, preserving raw bytes exactly.
public struct JPEGSegment: Equatable, Sendable {
  public var marker: UInt8        // 0xFF-prefixed marker byte (e.g. 0xE0 for APP0)
  public var offset: Int          // byte offset in the source stream
  public var payload: [UInt8]     // includes the length bytes if the marker has them

  public init(marker: UInt8, offset: Int, payload: [UInt8]) {
    self.marker = marker
    self.offset = offset
    self.payload = payload
  }
}

/// The image-coding content of a JPEG, byte-exact.
public struct JPEGStructure: Equatable, Sendable {
  /// All non-entropy-coded segments between SOI and SOS, byte-exact.
  public var segments: [JPEGSegment]
  /// Byte-exact entropy-coded scan data plus any trailing bytes through EOI.
  public var scanAndEOI: [UInt8]
  /// APP0/APP1 Exif payload bytes if present (raw, unparsed).
  public var exifSegment: JPEGSegment?
  /// APP1 XMP payload bytes if present (raw).
  public var xmpSegment: JPEGSegment?
  /// APP2 ICC profile payload bytes if present (raw, possibly chunked).
  public var iccSegments: [JPEGSegment]
  /// All other APPn segments (unknown metadata).
  public var unknownAPPSegments: [JPEGSegment]
  /// Total byte length of the original stream.
  public var originalLength: Int

  /// The full original byte stream can be reconstructed from segments + scan.
  public func reconstructedBytes() -> [UInt8] {
    var out: [UInt8] = [0xFF, 0xD8] // SOI
    for seg in segments {
      out.append(0xFF)
      out.append(seg.marker)
      out.append(contentsOf: seg.payload)
    }
    out.append(contentsOf: scanAndEOI)
    return out
  }
}

/// Parses a JPEG stream without decoding image data. Rejects malformed or
/// incomplete input instead of silently repairing it.
public enum JPEGParser {
  public static func parse(_ data: [UInt8]) throws -> JPEGStructure {
    guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
      throw JPEGError.notAJPEG
    }
    var segments: [JPEGSegment] = []
    var exif: JPEGSegment?
    var xmp: JPEGSegment?
    var icc: [JPEGSegment] = []
    var unknown: [JPEGSegment] = []
    var i = 2
    while i < data.count {
      if data[i] != 0xFF {
        // Bytes before a marker inside the header region: malformed.
        throw JPEGError.malformedSegment(marker: 0, offset: i)
      }
      // Skip fill bytes.
      var markerIdx = i
      while markerIdx < data.count && data[markerIdx] == 0xFF { markerIdx += 1 }
      if markerIdx >= data.count {
        throw JPEGError.truncated
      }
      let marker = data[markerIdx]
      let segStart = i
      switch marker {
      case 0xD8, 0x01, 0xD0...0xD7: // RSTn, TEM: no length field
        // Not expected between SOI and SOS in normal streams; treat as header.
        segments.append(JPEGSegment(marker: marker, offset: segStart, payload: []))
        i = markerIdx + 1
      case 0xD9: // EOI before SOS: no image data
        throw JPEGError.malformedSegment(marker: marker, offset: segStart)
      case 0xDA: // Start of Scan — everything from here is scan data + EOI.
        let scanAndEOI = Array(data[segStart...])
        guard scanAndEOI.count >= 2, scanAndEOI.endsScanCorrectly() else {
          throw JPEGError.truncated
        }
        return JPEGStructure(
          segments: segments,
          scanAndEOI: scanAndEOI,
          exifSegment: exif,
          xmpSegment: xmp,
          iccSegments: icc,
          unknownAPPSegments: unknown,
          originalLength: data.count)
      default:
        // Length-bearing marker.
        if markerIdx + 2 >= data.count {
          throw JPEGError.truncated
        }
        let len = (Int(data[markerIdx + 1]) << 8) | Int(data[markerIdx + 2])
        if len < 2 { throw JPEGError.malformedSegment(marker: marker, offset: segStart) }
        let payloadEnd = markerIdx + 1 + len
        if payloadEnd > data.count { throw JPEGError.truncated }
        let payload = Array(data[markerIdx + 1..<payloadEnd])
        let seg = JPEGSegment(marker: marker, offset: segStart, payload: payload)
        segments.append(seg)
        // Classify metadata-bearing segments.
        if marker == 0xE1, payload.count >= 6,
           payload[2] == 0x68, payload[3] == 0x74, payload[4] == 0x74, payload[5] == 0x70 {
          // "http://ns.adobe.com/xap/1.0/" XMP marker.
          if xmp == nil { xmp = seg } else { unknown.append(seg) }
        } else if marker == 0xE1, payload.count >= 6,
                  payload[2] == 0x45, payload[3] == 0x78, payload[4] == 0x69,
                  payload[5] == 0x66, payload[6] == 0x00 {
          // "Exif\0" marker.
          if exif == nil { exif = seg } else { unknown.append(seg) }
        } else if marker == 0xE2, payload.count >= 13,
                  payload[2] == 0x49, payload[3] == 0x43, payload[4] == 0x43,
                  payload[5] == 0x5F, payload[6] == 0x50, payload[7] == 0x52,
                  payload[8] == 0x4F, payload[9] == 0x46, payload[10] == 0x49,
                  payload[11] == 0x4C, payload[12] == 0x45 {
          // "ICC_PROFILE" marker (possibly chunked).
          icc.append(seg)
        } else if (0xE0...0xEF).contains(marker) {
          unknown.append(seg)
        }
        i = payloadEnd
      }
    }
    throw JPEGError.truncated
  }
}

extension Array where Element == UInt8 {
  func endsScanCorrectly() -> Bool {
    guard count >= 2 else { return false }
    // Trailing EOI (FFD9) is required for a complete JPEG.
    if self[count - 2] == 0xFF && self[count - 1] == 0xD9 { return true }
    return false
  }
}

/// Rebuilds a JPEG with metadata inserted, preserving all image-coding bytes.
/// This is a metadata-only path: image-coding segments and scan payload are
/// byte-identical before and after.
public enum JPEGMetadataWriter {
  /// Insert additional APP1 XMP and/or Exif segments without touching the
  /// image-coding data. Where safe merging is impossible (e.g. a source Exif
  /// block with MakerNotes), the source metadata is preserved as-is and
  /// additional observations go to XMP — never rewriting Exif in place.
  public static func withAdditionalMetadata(
    original: [UInt8],
    additionalXMP: [UInt8]? = nil,
    additionalExif: [UInt8]? = nil
  ) throws -> [UInt8] {
    let structure = try JPEGParser.parse(original)
    var newSegments: [JPEGSegment] = []
    // Insert new APP1 segments immediately after existing APP0/APP1 header
    // cluster (or right after SOI if none), never after scan data.
    var inserted = false
    for seg in structure.segments {
      if !inserted, additionalXMP != nil || additionalExif != nil, seg.marker != 0xE0 {
        if let xmp = additionalXMP {
          newSegments.append(makeXMPSegment(xmp))
        }
        if let exif = additionalExif {
          newSegments.append(makeExifSegment(exif))
        }
        inserted = true
      }
      newSegments.append(seg)
    }
    if !inserted {
      if let xmp = additionalXMP { newSegments.append(makeXMPSegment(xmp)) }
      if let exif = additionalExif { newSegments.append(makeExifSegment(exif)) }
    }
    var out: [UInt8] = [0xFF, 0xD8]
    for seg in newSegments {
      out.append(0xFF)
      out.append(seg.marker)
      out.append(contentsOf: seg.payload)
    }
    out.append(contentsOf: structure.scanAndEOI)
    return out
  }

  static func makeXMPSegment(_ xmp: [UInt8]) -> JPEGSegment {
    let header: [UInt8] = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0x00]
    let payloadLen = header.count + xmp.count + 2
    precondition(payloadLen <= 0xFFFF, "XMP payload too long for JPEG APP1")
    let lenBytes: [UInt8] = [
      UInt8((payloadLen >> 8) & 0xFF), UInt8(payloadLen & 0xFF),
    ]
    return JPEGSegment(marker: 0xE1, offset: 0, payload: lenBytes + header + xmp)
  }

  static func makeExifSegment(_ tiff: [UInt8]) -> JPEGSegment {
    let header: [UInt8] = Array("Exif\0".utf8) + [0x00]
    let payloadLen = header.count + tiff.count + 2
    precondition(payloadLen <= 0xFFFF, "Exif payload too long for JPEG APP1")
    let lenBytes: [UInt8] = [
      UInt8((payloadLen >> 8) & 0xFF), UInt8(payloadLen & 0xFF),
    ]
    return JPEGSegment(marker: 0xE1, offset: 0, payload: lenBytes + header + tiff)
  }
}
