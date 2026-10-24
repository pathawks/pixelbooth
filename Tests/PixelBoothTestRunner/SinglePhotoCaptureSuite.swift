import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary

private func selectionCamera(
  _ id: String, kind: CameraDevice.Kind = .external,
  transport: UInt32? = UInt32(kAudioDeviceTransportTypeUSB)
) -> CameraDevice {
  CameraDevice(uniqueID: id, localizedName: id, kind: kind, transportType: transport)
}

private actor AcquisitionTestGate {
  private var open = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !open else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    open = true
    continuation?.resume()
    continuation = nil
  }
}

private func singlePhotoFrame(generation: Int) throws -> DeliveredFrame {
  var pixel: CVPixelBuffer?
  guard
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel)
      == kCVReturnSuccess, let pixel
  else { throw SinglePhotoCaptureError.rejectedFrame("synthetic pixel allocation") }
  var format: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
    let format
  else { throw SinglePhotoCaptureError.rejectedFrame("synthetic format description") }
  let now = DispatchTime.now().uptimeNanoseconds
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: Int64(now), timescale: 1_000_000_000),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
  else { throw SinglePhotoCaptureError.rejectedFrame("synthetic sample buffer") }
  return DeliveredFrame(
    sampleBuffer: sample, generation: generation, deviceUniqueID: "fixture",
    fourCC: PixelFormatFourCC.bgra, width: 2, height: 2, timestampNanos: now,
    hostMonotonicNanos: now, hostWallClockISO: "2026-10-24T12:00:00Z")
}

func runSinglePhotoCaptureSuite() async {
  suite("SinglePhotoCapture")

  await test("USB pair selection ranks modes across cameras without descriptors") {
    let a = selectionCamera("usb-a")
    let b = selectionCamera("usb-b")
    let builtin = selectionCamera("builtin", kind: .builtIn, transport: nil)
    let selected = try SinglePhotoSelection.select(
      cameras: [builtin, b, a],
      modesByDevice: [
        a.id: [mkMode(640, 480, PixelFormatFourCC.bgra, 30, device: a.id)],
        b.id: [mkMode(1920, 1080, PixelFormatFourCC.mjpeg, 30, device: b.id)],
        builtin.id: [mkMode(4000, 3000, PixelFormatFourCC.bgra, 30, device: builtin.id)],
      ])
    check(selected.camera.id == b.id, "largest supported USB mode beats other USB/built-in cameras")
    check(
      selected.camera.usbIdentity == nil, "USB eligibility does not require descriptor matching")
  }

  await test("builtin fallback excludes virtual and non-USB external cameras") {
    let builtin = selectionCamera("builtin", kind: .builtIn, transport: nil)
    let virtual = selectionCamera("virtual", transport: UInt32(kAudioDeviceTransportTypeVirtual))
    let continuity = selectionCamera("continuity", kind: .other)
    let selected = try SinglePhotoSelection.select(
      cameras: [virtual, continuity, builtin],
      modesByDevice: [
        virtual.id: [mkMode(4000, 3000, PixelFormatFourCC.bgra, 30, device: virtual.id)],
        continuity.id: [mkMode(4000, 3000, PixelFormatFourCC.bgra, 30, device: continuity.id)],
        builtin.id: [mkMode(640, 480, PixelFormatFourCC.bgra, 30, device: builtin.id)],
      ])
    check(selected.camera.id == builtin.id, "only an actual built-in camera supplies fallback")
  }

  await test("unsupported USB does not activate builtin fallback") {
    let usb = selectionCamera("usb")
    let builtin = selectionCamera("builtin", kind: .builtIn)
    do {
      _ = try SinglePhotoSelection.select(
        cameras: [usb, builtin],
        modesByDevice: [
          usb.id: [mkMode(640, 480, PixelFormatFourCC.v210, 30, device: usb.id)],
          builtin.id: [mkMode(640, 480, PixelFormatFourCC.bgra, 30, device: builtin.id)],
        ])
      check(false, "unsupported USB camera must report failure")
    } catch let error as SinglePhotoCaptureError {
      check(error == .noSupportedMode, "unsupported USB mode is reported explicitly")
    }
  }

  await test("codec stays ahead of precision and supported layouts stay bounded") {
    let camera = selectionCamera("usb")
    let uncompressed = mkMode(640, 480, PixelFormatFourCC.bgra, 30, bits: 8, device: camera.id)
    let jpeg = mkMode(640, 480, PixelFormatFourCC.mjpeg, 30, bits: 12, device: camera.id)
    let selected = try SinglePhotoSelection.select(
      cameras: [camera], modesByDevice: [camera.id: [jpeg, uncompressed]])
    check(selected.mode == uncompressed, "uncompressed wins before bit depth")
    check(
      !SinglePhotoSelection.supports(
        mkMode(640, 480, PixelFormatFourCC.mjpeg, 30, bits: 16)),
      "true 16-bit modes remain unsupported")
    check(
      !SinglePhotoSelection.supports(mkMode(640, 480, PixelFormatFourCC.x422, 30)),
      "a classified layout without an archival adapter is not advertised")
    check(
      !SinglePhotoSelection.supports(mkMode(Int.max, 2, PixelFormatFourCC.bgra, 30)),
      "selection rejects overflowing geometry before ranking")
  }

  await test("mode merge includes AVFoundation-only maximum and requires exact equivalence") {
    let camera = selectionCamera("usb")
    let cmio = mkMode(
      640, 480, PixelFormatFourCC.bgra, 30, device: camera.id, formatID: "cmio-exact")
    let duplicate = mkMode(
      640, 480, PixelFormatFourCC.bgra, 30, device: camera.id, formatID: "0")
    let distinctDescription = mkMode(
      640, 480, PixelFormatFourCC.bgra, 60, device: camera.id, formatID: "1")
    let maximum = mkMode(
      1920, 1080, PixelFormatFourCC.bgra, 30, device: camera.id, formatID: "2")
    let distinctRate = mkMode(
      640, 480, PixelFormatFourCC.bgra, 60, device: camera.id, formatID: "3")
    let merged = SinglePhotoSelection.mergeModes(
      cmio: [cmio],
      advertised: [
        (duplicate, "cmio-exact"), (distinctDescription, "cmio-other"), (maximum, "cmio-maximum"),
        (distinctRate, "cmio-exact"),
      ])
    check(
      merged == [cmio, distinctDescription, maximum, distinctRate],
      "only exact representation and rate duplicates use CMIO capabilities")
    let selected = try SinglePhotoSelection.select(
      cameras: [camera], modesByDevice: [camera.id: merged])
    check(selected.mode == maximum, "AVFoundation-only maximum remains eligible")
    check(selected.mode.formatID == "2", "AVFoundation-only mode retains its exact indexed route")
  }

  await test("CLI ranks full RGB color above same-depth subsampled YUV") {
    let camera = selectionCamera("usb")
    let rgb = mkMode(
      640, 480, PixelFormatFourCC.bgra, 30, bits: 8, device: camera.id)
    let yuv420 = mkMode(
      640, 480, PixelFormatFourCC.nv12, 60, bits: 8, chroma: .yuv420, device: camera.id)
    let yuv422 = mkMode(
      640, 480, PixelFormatFourCC.yuvs, 60, bits: 8, chroma: .yuv422, device: camera.id)
    for yuv in [yuv420, yuv422] {
      let selected = try SinglePhotoSelection.select(
        cameras: [camera], modesByDevice: [camera.id: [yuv, rgb]])
      check(selected.mode == rgb, "full per-pixel RGB components beat same-depth subsampled color")
      check(
        selected.mode.chromaSampling == nil,
        "RGB metadata remains RGB without invented YUV sampling")
    }
    check(
      ModeSelector.compare(rgb, yuv420) == .orderedAscending,
      "the default comparator preserves the GUI's existing ranking")
  }

  await test("CLI keeps bit depth ahead of RGB full-color detail") {
    let camera = selectionCamera("usb")
    let rgb = mkMode(
      640, 480, PixelFormatFourCC.bgra, 60, bits: 8, device: camera.id)
    let yuv = mkMode(
      640, 480, PixelFormatFourCC.x420, 30, bits: 10, chroma: .yuv420, device: camera.id)
    let selected = try SinglePhotoSelection.select(
      cameras: [camera], modesByDevice: [camera.id: [rgb, yuv]])
    check(selected.mode == yuv, "10-bit YUV420 wins before RGB8's full color detail")
  }

  await test("selection is deterministic and ignores disconnected cameras") {
    let a = selectionCamera("a")
    let b = selectionCamera("b")
    var gone = selectionCamera("gone")
    gone.deviceConnected = false
    let modes = [
      a.id: [mkMode(640, 480, PixelFormatFourCC.bgra, 30, device: a.id)],
      b.id: [mkMode(640, 480, PixelFormatFourCC.bgra, 30, device: b.id)],
      gone.id: [mkMode(4000, 3000, PixelFormatFourCC.bgra, 30, device: gone.id)],
    ]
    let first = try SinglePhotoSelection.select(cameras: [gone, b, a], modesByDevice: modes)
    let second = try SinglePhotoSelection.select(cameras: [a, b, gone], modesByDevice: modes)
    check(first == second && first.camera.id == a.id, "stable mode identity resolves final ties")
  }

  await test("shared ingestion gates readiness on active generation and clears stopped frames") {
    let ingest = CaptureFrameIngest()
    await ingest.setReadinessHeuristic(
      ReadinessHeuristic(minimumFreshFrames: 1, minimumMillisecondsSinceValidStart: 0))
    await ingest.beginConfiguration(
      deviceID: "fixture", generation: 1, frameIntervalNanos: 1_000_000_000,
      expectedFormat: CaptureFormat(width: 2, height: 2, fourCC: PixelFormatFourCC.bgra))
    ingest.receive(try singlePhotoFrame(generation: 0))
    try await Task.sleep(nanoseconds: 20_000_000)
    let old = await ingest.newestFreshFrame(timeoutNanos: 0)
    check(old == nil, "a callback from an obsolete configuration cannot reach the shutter")
    ingest.receive(try singlePhotoFrame(generation: 1))
    let accepted = await ingest.newestFreshFrame(timeoutNanos: 200_000_000)
    check(accepted != nil, "shared ingestion retains the current complete frame")
    var readiness = await ingest.currentReadiness()
    for _ in 0..<40 {
      if readiness == .ready { break }
      try await Task.sleep(nanoseconds: 5_000_000)
      readiness = await ingest.currentReadiness()
    }
    check(readiness == .ready, "shared ingestion applies readiness to accepted frames")
    ingest.streamStopped(.init(reason: .stopped, deviceUniqueID: "fixture", generation: 1))
    try await Task.sleep(nanoseconds: 20_000_000)
    let stopped = await ingest.newestFreshFrame(timeoutNanos: 0)
    check(
      stopped == nil && ingest.stoppedStream != nil, "delivery stop clears retained shutter data")
  }

  await test("shared ingestion rejects selected versus delivered color-model changes") {
    let ingest = CaptureFrameIngest()
    await ingest.beginConfiguration(
      deviceID: "fixture", generation: 1, frameIntervalNanos: 1_000_000_000,
      expectedFormat: CaptureFormat(width: 2, height: 2, fourCC: PixelFormatFourCC.nv12))
    ingest.receive(try singlePhotoFrame(generation: 1))
    for _ in 0..<40 {
      if ingest.lastFailureMessage != nil { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    check(ingest.lastFailureMessage != nil, "known conversion remains an explicit capture failure")
    let readiness = await ingest.currentReadiness()
    check(readiness == .noStream, "mismatched frames do not count toward readiness")
  }

  await test("deadline returns successful acquisition without aborting") {
    let token = CaptureConfigurationToken()
    token.publish(1)
    let result = try await CaptureAcquisitionDeadline.run(
      timeoutSeconds: 1, onAbort: { token.publish(0) }
    ) { "complete" }
    check(result == "complete", "completed value is preserved")
    check(token.isCurrent(1), "successful acquisition does not invoke timeout cleanup")
  }

  await test("deadline does not await a platform operation that ignores cancellation") {
    let gate = AcquisitionTestGate()
    let token = CaptureConfigurationToken()
    token.publish(1)
    let start = ContinuousClock.now
    do {
      _ = try await CaptureAcquisitionDeadline.run(
        timeoutSeconds: 1, onAbort: { token.publish(0) }
      ) {
        await gate.wait()
        return "too late"
      }
      check(false, "a blocked acquisition must time out")
    } catch let error as SinglePhotoCaptureError {
      check(error == .timedOut(seconds: 1), "timeout reports the configured integer seconds")
    }
    check(
      start.duration(to: .now) < .seconds(3), "deadline does not wait for stalled platform work")
    check(token.isCurrent(0), "timeout invalidates the backend before returning")
    await gate.release()
  }

  await test("cancellation ends the deadline and invalidates backend startup") {
    let gate = AcquisitionTestGate()
    let token = CaptureConfigurationToken()
    token.publish(1)
    let capture = Task {
      try await CaptureAcquisitionDeadline.run(
        timeoutSeconds: 10, onAbort: { token.publish(0) }
      ) {
        await gate.wait()
        return "cancelled"
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    capture.cancel()
    do {
      _ = try await capture.value
      check(false, "cancelled acquisition must throw")
    } catch is CancellationError {
      check(token.isCurrent(0), "cancellation invalidates pending backend startup")
    }
    await gate.release()
  }

  await test("deadline rejects zero negative and overflowing timeouts") {
    for seconds in [0, -1, Int.max] {
      do {
        _ = try await CaptureAcquisitionDeadline.run(timeoutSeconds: seconds) { true }
        check(false, "invalid timeout must be rejected")
      } catch let error as SinglePhotoCaptureError {
        check(error == .invalidTimeout, "invalid integer timeout is reported")
      }
    }
  }
}
