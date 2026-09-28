// Frame adaptation for the save pipeline: turns an accepted capture's pixel
// buffer into a PlanarImage via the pure adapters, or extracts a complete
// JPEG from a native MJPEG sample. Unsupported representations are rejected,
// never silently normalized.

import Foundation
import AVFoundation
import CoreVideo
import PixelBoothCore
import PixelBoothAdapters
import PixelBoothJPEG

public enum FrameExtraction {
  /// FourCCs the archival path supports today. Each entry has adapter tests;
  /// a layout is advertised only after its adapter passes tests.
  public static let supportedPixelFormats: [UInt32] = [
    0x4e563132, // NV12 (bi-planar 8-bit 4:2:0)
    0x76303234, // 420v
    0x66303234, // 420f
    0x42475241, // BGRA
    0x32757976, // YUY2 ("2yuv")
    0x73757679, // UYVY ("yuvs")
  ]

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
      let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: ptr)
      if status != kCMBlockBufferNoErr { return 0 }
      return totalLength
    }
    guard copied == totalLength else { throw JPEGError.truncated }
    let bytes = [UInt8](data)
    // Parse to validate completeness; do not repair.
    _ = try JPEGParser.parse(bytes)
    return bytes
  }

  /// Adapt an uncompressed pixel buffer to a PlanarImage.
  public static func adapt(_ pixelBuffer: CVPixelBuffer, fourCC: UInt32) throws -> PlanarImage {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let deliveredFourCC = CVPixelBufferGetPixelFormatType(pixelBuffer)
    // Evidence rule (TN3121): the delivered pixel buffer's own format governs
    // the archival path. A negotiated FourCC that differs means macOS
    // performed a known conversion; we preserve the delivered representation.
    let relevant = deliveredFourCC

    switch relevant {
    case 0x42475241: // BGRA
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw AdapterError.planeUnavailable }
      return try SampleLayoutAdapter.adaptBGRA32(
        data: UnsafeRawPointer(base),
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height)
    case 0x34323076, // "420v" (delivered NV12 bi-planar 8-bit 4:2:0)
         0x4e563132, // "NV12"
         0x66303234: // "420f"
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
        throw AdapterError.planeUnavailable
      }
      return try SampleLayoutAdapter.adaptNV12(
        yPlane: UnsafeRawPointer(yBase), yBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
        chromaPlane: UnsafeRawPointer(chromaBase),
        chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
        width: width, height: height)
    case 0x32757976, 0x73757679: // YUY2, UYVY
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw AdapterError.planeUnavailable }
      let yFirst = relevant == 0x32757976
      return try SampleLayoutAdapter.adaptPacked422(
        data: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: width, height: height, yFirst: yFirst)
    default:
      throw AdapterError.unsupportedFourCC(relevant)
    }
  }
}

extension AdapterError {
  static var planeUnavailable: AdapterError { .invalidDimensions(width: 0, height: 0) }
}
