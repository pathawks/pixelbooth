// Frame adaptation for the save pipeline: turns an accepted capture's pixel
// buffer into a PlanarImage via the pure adapters, or extracts a complete
// JPEG from a native MJPEG sample. Unsupported representations are rejected,
// never silently normalized.
//
// Format evidence rule: the switch is on the CVPixelBuffer's own OSType
// (byte-exact FourCC, see PixelFormatFourCC) — the negotiated UVC FourCC can
// differ (UVC UYVY "yuvs" is delivered as pixel-buffer '2vuy').

import AVFoundation
import CoreVideo
import Foundation
import PixelBoothAdapters
import PixelBoothCore
import PixelBoothJPEG

public enum FrameExtraction {
  /// OSTypes the archival path supports today. Each entry has adapter tests;
  /// a layout is advertised only after its adapter passes tests.
  public static let supportedPixelFormats = PixelFormatFourCC.nativePlaneFormats

  /// Field interpretation is not represented by the archival JPEG/AVIF
  /// formats. Refuse it rather than silently treating fields as a progressive
  /// full frame.
  public enum FieldMetadataError: Error, Equatable, LocalizedError {
    case interlacedFieldCount(Int)
    case fieldDetailPresent(String)
    case conflictingFieldMetadata(String)
    case malformedFieldMetadata(String)

    public var errorDescription: String? {
      switch self {
      case .interlacedFieldCount(let count):
        return
          "This frame declares \(count) fields. PixelBooth only preserves progressive frames; select a progressive camera mode."
      case .fieldDetailPresent(let detail):
        return
          "This frame declares \(detail) field order. PixelBooth cannot preserve field-based frames; select a progressive camera mode."
      case .conflictingFieldMetadata(let field):
        return
          "The frame has conflicting \(field) values on its pixel buffer and format description."
      case .malformedFieldMetadata(let field):
        return
          "The frame has malformed or unsupported \(field) metadata, so its field interpretation cannot be verified."
      }
    }
  }

  /// Check field markers on the delivered pixel buffer and on both the
  /// delivered and source format descriptions. Source metadata matters for
  /// decoded inputs such as H.264, while the delivered description describes
  /// the image buffer that would otherwise be archived.
  public static func validateProgressiveFrame(
    sampleBuffer: CMSampleBuffer, sourceSampleBuffer: CMSampleBuffer? = nil
  ) throws {
    let formatDescriptions = [
      CMSampleBufferGetFormatDescription(sampleBuffer),
      sourceSampleBuffer.flatMap(CMSampleBufferGetFormatDescription),
    ]
    try validateProgressive(
      pixelBuffer: CMSampleBufferGetImageBuffer(sampleBuffer),
      formatDescriptions: formatDescriptions)
  }

  /// Validate the representation before adapting or copying its samples.
  /// Missing field markers are allowed. A declared two-field representation,
  /// any field-order detail, malformed value, or contradictory evidence fails.
  public static func validateProgressive(
    pixelBuffer: CVPixelBuffer?, formatDescriptions: [CMFormatDescription?] = []
  ) throws {
    var fieldCount: Int?
    var fieldDetail: String?

    func recordCount(_ value: CFTypeRef) throws {
      guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else {
        throw FieldMetadataError.malformedFieldMetadata("field count")
      }
      let rawValue = number.doubleValue
      guard rawValue.isFinite, rawValue.rounded(.towardZero) == rawValue,
        rawValue == 1 || rawValue == 2
      else {
        throw FieldMetadataError.malformedFieldMetadata("field count")
      }
      let value = Int(rawValue)
      if let existing = fieldCount, existing != value {
        throw FieldMetadataError.conflictingFieldMetadata("field count")
      }
      fieldCount = value
    }

    func recordDetail(_ value: CFTypeRef) throws {
      guard CFGetTypeID(value) == CFStringGetTypeID() else {
        throw FieldMetadataError.malformedFieldMetadata("field detail")
      }
      let rawValue = unsafeDowncast(value, to: CFString.self)
      let knownDetails: [(CFString, String)] = [
        (kCVImageBufferFieldDetailTemporalTopFirst, "temporal top first"),
        (kCVImageBufferFieldDetailTemporalBottomFirst, "temporal bottom first"),
        (kCVImageBufferFieldDetailSpatialFirstLineEarly, "spatial first line early"),
        (kCVImageBufferFieldDetailSpatialFirstLineLate, "spatial first line late"),
      ]
      guard let detail = knownDetails.first(where: { CFEqual(rawValue, $0.0) })?.1 else {
        throw FieldMetadataError.malformedFieldMetadata("field detail")
      }
      if let existing = fieldDetail, existing != detail {
        throw FieldMetadataError.conflictingFieldMetadata("field detail")
      }
      fieldDetail = detail
    }

    if let pixelBuffer {
      if let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferFieldCountKey, nil) {
        try recordCount(value)
      }
      if let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferFieldDetailKey, nil) {
        try recordDetail(value)
      }
    }

    for description in formatDescriptions.compactMap({ $0 }) {
      let extensions =
        CMFormatDescriptionGetExtensions(description) as? [CFString: Any] ?? [:]
      if let value = extensions[kCVImageBufferFieldCountKey] as CFTypeRef? {
        try recordCount(value)
      }
      if let value = extensions[kCVImageBufferFieldDetailKey] as CFTypeRef? {
        try recordDetail(value)
      }
    }

    if let fieldCount, fieldCount == 2 {
      throw FieldMetadataError.interlacedFieldCount(fieldCount)
    }
    if let fieldDetail {
      throw FieldMetadataError.fieldDetailPresent(fieldDetail)
    }
  }

  /// Extract a complete JPEG from a native MJPEG sample buffer, byte-exact.
  public static func extractJPEG(from sampleBuffer: CMSampleBuffer) throws -> [UInt8] {
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw JPEGError.notAJPEG
    }
    let totalLength = CMBlockBufferGetDataLength(block)
    guard totalLength > 0 else { throw JPEGError.truncated }
    var data = Data(count: totalLength)
    let copied = data.withUnsafeMutableBytes { raw -> Int in
      guard let ptr = raw.baseAddress else { return 0 }
      let status = CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: totalLength, destination: ptr)
      if status != kCMBlockBufferNoErr { return 0 }
      return totalLength
    }
    guard copied == totalLength else { throw JPEGError.truncated }
    let bytes = [UInt8](data)
    // Parse to validate completeness; do not repair.
    _ = try JPEGParser.parse(bytes)
    return bytes
  }

  /// Adapt an uncompressed pixel buffer to a PlanarImage. The delivered
  /// pixel-buffer OSType governs the path (evidence rule); a negotiated
  /// FourCC that differs means macOS performed a known conversion.
  public static func adapt(_ pixelBuffer: CVPixelBuffer, fourCC: UInt32) throws -> PlanarImage {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else { throw AdapterError.planeUnavailable }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    return try adaptLocked(pixelBuffer, fourCC: fourCC)
  }

  private static func adaptLocked(_ pixelBuffer: CVPixelBuffer, fourCC: UInt32) throws
    -> PlanarImage
  {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    let deliveredFourCC = CVPixelBufferGetPixelFormatType(pixelBuffer)

    switch deliveredFourCC {
    case PixelFormatFourCC.bgra:  // BGRA
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AdapterError.planeUnavailable
      }
      return try SampleLayoutAdapter.adaptBGRA32(
        data: UnsafeRawPointer(base),
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height)
    case PixelFormatFourCC.bgr24:
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AdapterError.planeUnavailable
      }
      return try adaptPackedRGB(
        data: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height, fourCC: deliveredFourCC)
    case PixelFormatFourCC.rgb24:
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AdapterError.planeUnavailable
      }
      return try adaptPackedRGB(
        data: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height, fourCC: deliveredFourCC)
    case PixelFormatFourCC.x420, PixelFormatFourCC.xf20:
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
      else { throw AdapterError.planeUnavailable }
      return try SampleLayoutAdapter.adaptBiPlanar10BitYUV(
        yPlane: UnsafeRawPointer(yBase),
        yBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
        chromaPlane: UnsafeRawPointer(chromaBase),
        chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
        width: width, height: height)
    case PixelFormatFourCC.fourTwentyV,  // '420v' NV12 bi-planar 4:2:0
      PixelFormatFourCC.fourTwentyF,  // '420f'
      PixelFormatFourCC.nv12:  // 'NV12'
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
      else {
        throw AdapterError.planeUnavailable
      }
      return try SampleLayoutAdapter.adaptNV12(
        yPlane: UnsafeRawPointer(yBase),
        yBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
        chromaPlane: UnsafeRawPointer(chromaBase),
        chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
        width: width, height: height)
    case PixelFormatFourCC.twoVuy:  // '2vuy': Cb Y Cr Y — UYVY order
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AdapterError.planeUnavailable
      }
      return try SampleLayoutAdapter.adaptPacked422(
        data: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height, yFirst: false)
    case PixelFormatFourCC.yuvs:  // 'yuvs': Y Cb Y Cr — YUY2 order
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AdapterError.planeUnavailable
      }
      return try SampleLayoutAdapter.adaptPacked422(
        data: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height, yFirst: true)
    default:
      // Reject with the exact delivered OSType for honest diagnostics.
      throw AdapterError.unsupportedFourCC(deliveredFourCC)
    }
  }

  /// Shared production seam for CoreVideo's non-alpha packed 24-bit RGB
  /// layouts; tests feed padded-stride fixtures through the same dispatch.
  public static func adaptPackedRGB(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, fourCC: UInt32
  ) throws -> PlanarImage {
    switch fourCC {
    case PixelFormatFourCC.bgr24:
      return try SampleLayoutAdapter.adaptBGR24(
        data: data, bytesPerRow: bytesPerRow, width: width, height: height)
    case PixelFormatFourCC.rgb24:
      return try SampleLayoutAdapter.adaptRGB24(
        data: data, bytesPerRow: bytesPerRow, width: width, height: height)
    default:
      throw AdapterError.unsupportedFourCC(fourCC)
    }
  }

  /// Snapshot while the CVPixelBuffer is locked, since some adapters borrow
  /// its plane addresses. Adapter-owned scratch planes are released afterward.
  public static func snapshot(
    _ pixelBuffer: CVPixelBuffer, fourCC: UInt32,
    formatDescriptions: [CMFormatDescription?] = []
  ) throws
    -> CapturedCapture.PlaneSnapshot
  {
    try validateProgressive(pixelBuffer: pixelBuffer, formatDescriptions: formatDescriptions)
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else { throw AdapterError.planeUnavailable }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let planar = try adaptLocked(pixelBuffer, fourCC: fourCC)
    defer { for pointer in planar.ownedStorage.compactMap({ $0 }) { pointer.deallocate() } }
    let snapshot = try CapturedCapture.snapshotPlanes(from: planar)
    try snapshot.validate(width: planar.width, height: planar.height)
    return snapshot
  }
}

extension AdapterError {
  static var planeUnavailable: AdapterError { .invalidDimensions(width: 0, height: 0) }
}
