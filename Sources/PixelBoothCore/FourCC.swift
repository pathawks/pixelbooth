import Foundation

/// Byte-exact FourCC/OSType construction, equivalent to the C `'xxxx'` literal.
/// '2vuy' -> 0x32767579, '420v' -> 0x34323076 (matches CVPixelBuffer OSTypes).
public func fourCC(_ s: String) -> UInt32 {
  precondition(s.count == 4, "FourCC must be exactly 4 characters")
  var value: UInt32 = 0
  for byte in s.utf8 {
    value = (value << 8) | UInt32(byte)
  }
  return value
}

/// Canonical CVPixelBuffer/AVFoundation OSTypes the archival pipeline sees.
/// These are byte-exact literals, not UVC descriptor FourCCs (which can differ
/// in byte order — e.g. UVC UYVY "yuvs" arrives as pixel-buffer '2vuy').
public enum PixelFormatFourCC {
  public static let mjpeg: UInt32 = fourCC("MJPG")  // 0x4D4A5047
  public static let jpeg: UInt32 = fourCC("jpeg")  // CoreMedia JPEG codec type
  public static let dmb1: UInt32 = fourCC("dmb1")  // CoreMedia OpenDML JPEG codec type
  public static let avc1: UInt32 = fourCC("avc1")  // 0x61766331
  public static let bgra: UInt32 = fourCC("BGRA")  // 0x42475241
  public static let bgr24: UInt32 = fourCC("24BG")  // CoreVideo 24-bit BGR
  public static let rgb24: UInt32 = 0x0000_0018  // CoreVideo 24-bit RGB
  public static let nv12: UInt32 = fourCC("NV12")  // 0x4E563132
  public static let fourTwentyV: UInt32 = fourCC("420v")  // 0x34323076
  public static let fourTwentyF: UInt32 = fourCC("420f")  // 0x34323066
  public static let twoVuy: UInt32 = fourCC("2vuy")  // 0x32767579 UYVY order
  public static let yuvs: UInt32 = fourCC("yuvs")  // 0x79757673 YUY2 order
  public static let y420: UInt32 = fourCC("y420")
  public static let x420: UInt32 = fourCC("x420")
  public static let xf20: UInt32 = fourCC("xf20")
  public static let x422: UInt32 = fourCC("x422")
  public static let xf22: UInt32 = fourCC("xf22")
  public static let x444: UInt32 = fourCC("x444")
  public static let xf44: UInt32 = fourCC("xf44")
  public static let v210: UInt32 = fourCC("v210")

  /// PixelBuffer plane layouts with a production archival adapter. Encoded
  /// JPEG is intentionally handled by its separate byte-preserving route.
  public static let nativePlaneFormats: [UInt32] = [
    fourTwentyV, fourTwentyF, nv12, twoVuy, yuvs,
    bgra, bgr24, rgb24, x420, xf20,
  ]

  public static func isJPEG(_ value: UInt32) -> Bool {
    value == mjpeg || value == jpeg || value == dmb1
  }

  public static func isRGB(_ value: UInt32) -> Bool {
    value == bgra || value == bgr24 || value == rgb24
      || value == fourCC("RGBA") || value == fourCC("ABGR")
  }

  /// Shared coding-family facts for discovery, mode ranking, and fidelity
  /// checks. Adapter availability remains the narrower nativePlaneFormats list.
  public static func codecFamily(_ value: UInt32) -> CaptureCodecFamily {
    if isJPEG(value) { return .nativeJPEG }
    if value == avc1 { return .h264 }
    if isRGB(value) { return .uncompressedRGB }
    if [
      nv12, fourTwentyV, fourTwentyF, twoVuy, yuvs, v210, x420, xf20, x422, xf22, x444, xf44, y420,
    ]
    .contains(value) {
      return .uncompressedYUV
    }
    return .unknown
  }

  public static func hasNativePlaneAdapter(_ value: UInt32) -> Bool {
    nativePlaneFormats.contains(value)
  }
}
