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
  public static func snapshot(_ pixelBuffer: CVPixelBuffer, fourCC: UInt32) throws
    -> CapturedCapture.PlaneSnapshot
  {
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
