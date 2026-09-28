// FourCC byte-exactness tests: the archival path switches on CVPixelBuffer
// OSTypes, so the Swift constants must equal the C 'xxxx' literals exactly.
// Regression: hand-computed constants had wrong byte order, so real formats
// (e.g. '420v') fell through to "unsupported representation".

import PixelBoothCore

func runFourCCSuite() async {
  suite("FourCC")

  await test("byteExactLiterals") {
    check(fourCC("2vuy") == 0x3276_7579, "'2vuy' packs to 0x32767579")
    check(fourCC("yuvs") == 0x7975_7673, "'yuvs' packs to 0x79757673")
    check(
      fourCC("420v") == 0x3432_3076,
      "'420v' packs to 0x34323076 (matches real OSType from hardware logs)")
    check(fourCC("420f") == 0x3432_3066, "'420f' packs to 0x34323066")
    check(fourCC("NV12") == 0x4E56_3132, "'NV12' packs to 0x4E563132")
    check(fourCC("BGRA") == 0x4247_5241, "'BGRA' packs to 0x42475241")
    check(fourCC("MJPG") == 0x4D4A_5047, "'MJPG' packs to 0x4D4A5047")
    check(fourCC("avc1") == 0x6176_6331, "'avc1' packs to 0x61766331")
  }

  await test("deliveredFormatsMatchHardwareLog") {
    // From docs/TN3121_VERIFICATION.md: the UVC camera advertises UYVY and
    // macOS delivers NV12. Both sides must round-trip through the helper.
    check(
      CaptureFormat.fourCCString(PixelFormatFourCC.fourTwentyV) == "420v",
      "delivered buffer decodes back as 420v")
    check(
      CaptureFormat.fourCCString(PixelFormatFourCC.twoVuy) == "2vuy",
      "UYVY pixel-buffer format decodes back as 2vuy")
  }

  await test("sharedFactsSeparateCodecFamiliesFromArchivalAdapters") {
    for jpeg in [PixelFormatFourCC.jpeg, PixelFormatFourCC.dmb1, PixelFormatFourCC.mjpeg] {
      check(PixelFormatFourCC.codecFamily(jpeg) == .nativeJPEG, "JPEG alias classified")
    }
    check(PixelFormatFourCC.codecFamily(PixelFormatFourCC.avc1) == .h264, "H.264 classified")
    check(
      PixelFormatFourCC.nativePlaneFormats.contains(PixelFormatFourCC.x420),
      "tested 10-bit bi-planar format has an archival adapter")
    check(
      !PixelFormatFourCC.nativePlaneFormats.contains(PixelFormatFourCC.v210),
      "packed v210 is not presented as an implemented planar adapter")
  }
}
