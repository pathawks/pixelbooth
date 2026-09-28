// Mode selection tests: area-first/width-second ranking, deterministic
// tie-breaking, uncompressed > MJPEG > H.264 preference, bit depth and
// chroma detail, maximum frame rate, and remembered selections.

import PixelBoothCore

func mkMode(
  _ w: Int, _ h: Int, _ fourCC: UInt32, _ maxRate: Double,
  bits: Int? = nil, chroma: CaptureFormat.ChromaSampling? = nil,
  device: String = "cam1", formatID: String? = nil
) -> CameraMode {
  CameraMode(
    deviceID: device, formatID: formatID, mediaSubType: fourCC,
    dimensions: (w, h), minFrameRate: maxRate / 2, maxFrameRate: maxRate,
    pixelFormat: fourCC, bitsPerChannel: bits, chromaSampling: chroma)
}

func runModeSelectorSuite() async {
  suite("ModeSelector")

  await test("largestAreaWinsBeforeFrameRate") {
    let big = mkMode(1920, 1080, 0x4d4a_5047, 30)  // MJPEG, low rate
    let small = mkMode(1280, 720, 0x4e56_3132, 120)  // NV12, high rate
    check(ModeSelector.preferredMode([small, big]) == big, "largest area must win")
  }

  await test("greaterWidthWinsAreaTie") {
    let wide = mkMode(640, 480, 0x4e56_3132, 30)
    let tall = mkMode(480, 640, 0x4e56_3132, 120)
    check(ModeSelector.preferredMode([tall, wide]) == wide, "greater width wins area tie")
  }

  await test("uncompressedPreferredOverMJPEGAndH264") {
    let h264 = mkMode(640, 480, 0x6176_6331, 30)
    let mjpeg = mkMode(640, 480, 0x4d4a_5047, 30)
    let nv12 = mkMode(640, 480, 0x4e56_3132, 30)
    check(ModeSelector.preferredMode([mjpeg, nv12]) == nv12, "uncompressed beats MJPEG")
    check(ModeSelector.preferredMode([h264, mjpeg]) == mjpeg, "MJPEG beats H.264")
    check(ModeSelector.preferredMode([h264, nv12]) == nv12, "uncompressed beats H.264")
  }

  await test("higherBitDepthAndChromaDetailWin") {
    let b8 = mkMode(640, 480, 0x4e56_3132, 30, bits: 8, chroma: .yuv420)
    let b10 = mkMode(640, 480, PixelFormatFourCC.x422, 30, bits: 10, chroma: .yuv422)
    check(ModeSelector.preferredMode([b8, b10]) == b10, "higher depth/chroma detail wins")
  }

  await test("higherMaximumFrameRateWins") {
    let r30 = mkMode(640, 480, 0x4e56_3132, 30)
    let r60 = mkMode(640, 480, 0x4e56_3132, 60)
    check(ModeSelector.preferredMode([r30, r60]) == r60, "higher max rate wins")
  }

  await test("stableIDDecidesFinalTie") {
    let a = mkMode(640, 480, 0x4e56_3132, 30, device: "cam1", formatID: "A")
    let b = mkMode(640, 480, 0x4e56_3132, 30, device: "cam1", formatID: "B")
    let chosen = ModeSelector.preferredMode([b, a])
    check(chosen?.stableID == min(a.stableID, b.stableID), "stable ID decides final tie")
  }

  await test("camera change: identical labels are different modes") {
    let onCam1 = mkMode(1920, 1080, 0x4d4a_5047, 30, device: "cam1", formatID: "0")
    let onCam2 = mkMode(1920, 1080, 0x4d4a_5047, 30, device: "cam2", formatID: "0")
    check(onCam1.descriptiveLabel == onCam2.descriptiveLabel, "fixture: labels match")
    check(onCam1.id != onCam2.id, "mode identity must be device-qualified")
    check(onCam1.stableID != onCam2.stableID, "stable identity must be device-qualified")
  }

  await test("secondaryPreferencesCannotOverrideArea") {
    let bigH264 = mkMode(1920, 1080, 0x6176_6331, 30)
    let smallNV12 = mkMode(320, 240, 0x4e56_3132, 120, bits: 10, chroma: .yuv444)
    check(
      ModeSelector.preferredMode([smallNV12, bigH264]) == bigH264,
      "secondary prefs must never override area/width")
  }

  await test("emptyModeListHasNoSelection") {
    check(ModeSelector.preferredMode([]) == nil, "empty list yields nil")
  }
}
