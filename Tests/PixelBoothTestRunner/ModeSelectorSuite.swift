// Mode selection tests: area-first/width-second ranking, deterministic
// tie-breaking, uncompressed > MJPEG > H.264 preference, bit depth and
// chroma detail, maximum frame rate, and remembered selections.

import PixelBoothCore

func mkMode(_ w: Int, _ h: Int, _ fourCC: UInt32, _ maxRate: Double,
            bits: Int? = nil, chroma: CaptureFormat.ChromaSampling? = nil,
            device: String = "cam1", formatID: String? = nil) -> CameraMode {
  CameraMode(deviceID: device, formatID: formatID, mediaSubType: fourCC,
             dimensions: (w, h), minFrameRate: maxRate / 2, maxFrameRate: maxRate,
             pixelFormat: fourCC, bitsPerChannel: bits, chromaSampling: chroma)
}

func runModeSelectorSuite() {
  suite("ModeSelector")

  test("areaFirstWidthSecond") {
    let big = mkMode(1920, 1080, 0x4d4a5047, 30)      // MJPEG, low rate
    let small = mkMode(1280, 720, 0x4e563132, 120)    // NV12, high rate
    check(ModeSelector.preferredMode([small, big]) == big, "largest area must win")
  }

  test("widthBreaksAreaTie") {
    let wide = mkMode(640, 480, 0x4e563132, 30)
    let tall = mkMode(480, 640, 0x4e563132, 120)
    check(ModeSelector.preferredMode([tall, wide]) == wide, "greater width wins area tie")
  }

  test("codecPreferenceOrder") {
    let h264 = mkMode(640, 480, 0x61766331, 30)
    let mjpeg = mkMode(640, 480, 0x4d4a5047, 30)
    let nv12 = mkMode(640, 480, 0x4e563132, 30)
    check(ModeSelector.preferredMode([mjpeg, nv12]) == nv12, "uncompressed beats MJPEG")
    check(ModeSelector.preferredMode([h264, mjpeg]) == mjpeg, "MJPEG beats H.264")
    check(ModeSelector.preferredMode([h264, nv12]) == nv12, "uncompressed beats H.264")
  }

  test("depthAndChromaDetailPreference") {
    let b8 = mkMode(640, 480, 0x4e563132, 30, bits: 8, chroma: .yuv420)
    let b10 = mkMode(640, 480, 0x32313276, 30, bits: 10, chroma: .yuv422)
    check(ModeSelector.preferredMode([b8, b10]) == b10, "higher depth/chroma detail wins")
  }

  test("frameRatePreferenceAtEqualQuality") {
    let r30 = mkMode(640, 480, 0x4e563132, 30)
    let r60 = mkMode(640, 480, 0x4e563132, 60)
    check(ModeSelector.preferredMode([r30, r60]) == r60, "higher max rate wins")
  }

  test("deterministicStableIDTieBreak") {
    let a = mkMode(640, 480, 0x4e563132, 30, device: "cam1", formatID: "A")
    let b = mkMode(640, 480, 0x4e563132, 30, device: "cam1", formatID: "B")
    let chosen = ModeSelector.preferredMode([b, a])
    check(chosen?.stableID == min(a.stableID, b.stableID), "stable ID decides final tie")
  }

  test("areaDominatesSecondary") {
    let bigH264 = mkMode(1920, 1080, 0x61766331, 30)
    let smallNV12 = mkMode(320, 240, 0x4e563132, 120, bits: 10, chroma: .yuv444)
    check(ModeSelector.preferredMode([smallNV12, bigH264]) == bigH264,
          "secondary prefs must never override area/width")
  }

  test("emptyListNil") {
    check(ModeSelector.preferredMode([]) == nil, "empty list yields nil")
  }
}
