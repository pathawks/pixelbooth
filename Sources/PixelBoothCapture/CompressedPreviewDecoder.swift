import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

/// Bounded, display-only JPEG decoding for CMIO samples that have no pixel
/// buffer. The caller keeps the original CMSampleBuffer for archival work.
public enum CompressedPreviewDecoder {
  public static let maximumCompressedBytes = 64 * 1024 * 1024
  public static let maximumImageDimension = 32_768
  public static let maximumDecodedPixels = 64 * 1024 * 1024

  public static func decodeJPEG(sampleBuffer: CMSampleBuffer) -> CGImage? {
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0, length <= maximumCompressedBytes else { return nil }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
      guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      return CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: length, destination: baseAddress)
    }
    guard status == kCMBlockBufferNoErr,
      data.starts(with: [0xFF, 0xD8]), data.suffix(2).elementsEqual([0xFF, 0xD9]),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else { return nil }
    let width = widthValue.intValue
    let height = heightValue.intValue
    let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0,
      width <= maximumImageDimension, height <= maximumImageDimension,
      !pixelCountOverflow, pixelCount <= maximumDecodedPixels,
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
      image.width == width, image.height == height
    else { return nil }
    return image
  }
}
