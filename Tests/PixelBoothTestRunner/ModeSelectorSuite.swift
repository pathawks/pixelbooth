// Mode selection tests: area-first/width-second ranking, deterministic
// tie-breaking, uncompressed > MJPEG > H.264 preference, bit depth and
// chroma detail, maximum frame rate, and remembered selections.

import Foundation
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

  await test("modeLabelsShowKnownUnknownAndFractionalFormatFacts") {
    let known = mkMode(
      1280, 720, PixelFormatFourCC.mjpeg, 29.97002997, bits: 8, chroma: .yuv420)
    check(
      known.descriptiveLabel
        == "1280×720 · MJPG · 8-bit · YUV420 · 29.97 fps max",
      "known precision, chroma, codec and fractional rate are visible")

    let unknown = mkMode(640, 480, PixelFormatFourCC.avc1, 0)
    check(
      unknown.descriptiveLabel
        == "640×480 · avc1 · unknown depth · unknown chroma · rate unknown",
      "unavailable depth, sampling and rate remain explicitly unknown")
    check(!unknown.descriptiveLabel.contains("0 fps"), "an unknown rate is never rendered as zero")

    let rgb = mkMode(640, 480, PixelFormatFourCC.bgra, 60, bits: 8)
    check(rgb.descriptiveLabel.contains("RGB"), "RGB modes identify sampling as not applicable")
    let nonFinite = CaptureFormat(
      width: 640, height: 480, fourCC: PixelFormatFourCC.nv12, maxFrameRate: .infinity)
    check(
      nonFinite.descriptiveLabel.contains("rate unknown"),
      "non-finite rates are not shown as measured capabilities")
  }

  await test("CMIO mode identity survives frame rate becoming known") {
    let unknownRate = mkMode(1280, 720, PixelFormatFourCC.nv12, 0)
    let reportedRate = mkMode(1280, 720, PixelFormatFourCC.nv12, 60)
    check(
      unknownRate.id == reportedRate.id,
      "transient CMIO frame-rate availability does not change mode identity")
    check(
      unknownRate.descriptiveLabel.contains("rate unknown"),
      "a mode without a reported rate is described as unknown")
    check(
      !unknownRate.descriptiveLabel.contains("0 fps"),
      "an unknown rate is not presented as zero fps")
  }

  await test("legacy rate-based remembered mode migrates when unique") {
    let mode = mkMode(1280, 720, PixelFormatFourCC.nv12, 60)
    let legacyID = "\(mode.legacyRateBasedIDPrefix)#0.00"
    let migrated = ModeSelector.rememberedMode(id: legacyID, in: [mode])
    check(migrated?.id == mode.id, "a unique legacy representation is migrated")

    let currentCMIOMode = mkMode(
      1280, 720, PixelFormatFourCC.nv12, 60, device: "legacy-cam", formatID: "cmio-current")
    let olderAVFoundationID = "legacy-cam#3#\(PixelFormatFourCC.nv12)#1280x720#60.00"
    let migratedAcrossFormatID = ModeSelector.rememberedMode(
      id: olderAVFoundationID, in: [currentCMIOMode])
    check(
      migratedAcrossFormatID?.id == currentCMIOMode.id,
      "a unique legacy mode migrates when its old AVFoundation format index is replaced")
  }

  await test("ambiguous legacy remembered mode requires reselection") {
    let limited = mkMode(1280, 720, PixelFormatFourCC.nv12, 60)
    var full = limited
    full.yuvRange = .full
    var limitedWithKnownRange = limited
    limitedWithKnownRange.yuvRange = .limited
    let legacyID = "\(limited.legacyRateBasedIDPrefix)#0.00"
    let resolved = ModeSelector.rememberedMode(
      id: legacyID, in: [limitedWithKnownRange, full])
    check(resolved == nil, "migration does not choose between distinct known ranges")

    let cmioA = mkMode(
      1280, 720, PixelFormatFourCC.nv12, 60, device: "legacy-cam", formatID: "cmio-a")
    let cmioB = mkMode(
      1280, 720, PixelFormatFourCC.nv12, 60, device: "legacy-cam", formatID: "cmio-b")
    let oldIndexedID = "legacy-cam#3#\(PixelFormatFourCC.nv12)#1280x720#60.00"
    let ambiguous = ModeSelector.rememberedMode(id: oldIndexedID, in: [cmioA, cmioB])
    check(ambiguous == nil, "format-ID changes do not choose between duplicate representations")
  }

  await test("remembered mode survives refresh and relaunch rate discovery") {
    let storedMode = mkMode(1280, 720, PixelFormatFourCC.nv12, 0, device: "persist-cam")
    let refreshedMode = mkMode(1280, 720, PixelFormatFourCC.nv12, 59.94, device: "persist-cam")
    let defaultsName = "PixelBoothModeIdentity-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    defaults.set(storedMode.id, forKey: "remembered")
    let restoredID = defaults.string(forKey: "remembered")!
    let restored = ModeSelector.rememberedMode(id: restoredID, in: [refreshedMode])
    check(storedMode.id == refreshedMode.id, "frame-rate discovery does not change stored identity")
    check(restored?.id == refreshedMode.id, "relaunch restores the same camera representation")
  }

  await test("format and device identity remain distinct") {
    let first = mkMode(1280, 720, PixelFormatFourCC.nv12, 30, device: "cam-a", formatID: "a")
    let secondFormat = mkMode(
      1280, 720, PixelFormatFourCC.nv12, 30, device: "cam-a", formatID: "b")
    let secondDevice = mkMode(
      1280, 720, PixelFormatFourCC.nv12, 30, device: "cam-b", formatID: "a")
    check(first.id != secondFormat.id, "different advertised format identities stay distinct")
    check(first.id != secondDevice.id, "different cameras stay distinct")
  }

  await test("enumeration publication rejects superseded and disconnected results") {
    let requestA1 = CameraEnumerationRequest(deviceID: "A", revision: 1)
    let requestB = CameraEnumerationRequest(deviceID: "B", revision: 2)
    let requestA3 = CameraEnumerationRequest(deviceID: "A", revision: 3)
    check(
      !requestA1.mayPublish(
        selectedDeviceID: "A", currentRevision: 3, windowActive: true, deviceConnected: true),
      "A-to-B-to-A change rejects the first A result")
    check(
      !requestB.mayPublish(
        selectedDeviceID: "A", currentRevision: 3, windowActive: true, deviceConnected: true),
      "late B result cannot replace the selected A modes")
    check(
      !requestA3.mayPublish(
        selectedDeviceID: "A", currentRevision: 3, windowActive: false, deviceConnected: true),
      "window closure rejects a pending enumeration")
    check(
      !requestA3.mayPublish(
        selectedDeviceID: "A", currentRevision: 3, windowActive: true, deviceConnected: false),
      "device removal rejects its pending formats")
    check(
      requestA3.mayPublish(
        selectedDeviceID: "A", currentRevision: 3, windowActive: true, deviceConnected: true),
      "only the current connected selection may publish")
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
