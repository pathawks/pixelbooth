// End-to-end hardware verification: real camera → immutable snapshot →
// lossless AVIF (speed 0) → decode-compare → journal. Writes to a local
// destination (no Photos TCC needed). Run on hardware with camera permission.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import PixelBoothCore
import PixelBoothCapture
import PixelBoothLibrary
import PixelBoothMetadata
import PixelBoothAdapters
import PixelBoothAVIF

@main
struct EndToEndProbe {
  static func main() async {
    print("=== PixelBooth end-to-end hardware probe ===")
    var status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .notDetermined {
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      status = AVCaptureDevice.authorizationStatus(for: .video)
      if !granted { print("DENIED"); exit(2) }
    }
    guard status == .authorized else { print("DENIED"); exit(2) }

    guard let device = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video, position: .unspecified).devices.first else {
      print("NO CAMERA"); exit(2)
    }
    print("Device: \(device.localizedName)")

    // Choose the largest-area data-output-capable mode deterministically.
    let modes: [CameraMode] = device.formats.map { fmt in
      let desc = fmt.formatDescription
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      let fourCC = CMFormatDescriptionGetMediaSubType(desc)
      let maxRate: Double = fmt.videoSupportedFrameRateRanges.first.map {
        $0.minFrameDuration.seconds > 0 ? 1.0 / $0.minFrameDuration.seconds : 0
      } ?? 0
      return CameraMode(deviceID: device.uniqueID, formatID: nil,
                        mediaSubType: fourCC, dimensions: (Int(dims.width), Int(dims.height)),
                        minFrameRate: 0, maxFrameRate: maxRate, pixelFormat: fourCC)
    }
    guard let mode = ModeSelector.preferredMode(modes) else { print("NO MODES"); exit(2) }
    print("Selected mode: \(mode.descriptiveLabel)")

    let service = CaptureService()
    do {
      try await service.configure(deviceUniqueID: device.uniqueID, mode: mode)
      try await service.start()
      await service.publishGeneration()
    } catch {
      print("CONFIG FAILED: \(error)")
      exit(2)
    }

    // Collect frames for 3 seconds of warm-up in the final mode.
    let collector = FrameCollector()
    await service.addSink(collector, queue: DispatchQueue(label: "probe.frames"))
    try? await Task.sleep(nanoseconds: 3_000_000_000)

    // Shutter: newest sufficiently fresh frame.
    guard let frame = await collector.newestFreshFrame(timeoutNanos: 1_000_000_000) else {
      print("NO FRESH FRAME")
      try? await service.stop(); exit(2)
    }
    print("Delivered frame: \(frame.width)×\(frame.height) fourCC=\(CaptureFormat.fourCCString(frame.fourCC))")
    let fidelity = CaptureDiscovery.classifyFidelity(
      negotiatedFourCC: mode.pixelFormat, deliveredFourCC: frame.fourCC)
    print("Fidelity classification: \(fidelity)")

    // Immutable snapshot at acceptance.
    let snapshot = await collector.snapshotMetadata(for: frame)
    let capture: CapturedCapture
    do {
      capture = try CapturedCapture(from: frame, metadata: snapshot)
    } catch {
      print("SNAPSHOT FAILED: \(error)")
      try? await service.stop(); exit(2)
    }
    try? await service.stop()

    // Archive through the save pipeline into a local destination.
    let staging = URL(fileURLWithPath: "/tmp/pixelbooth-e2e-\(UUID().uuidString.prefix(8))")
    let queue = SaveQueueActor(stagingRoot: staging.appendingPathComponent("staging"))
    let queued = await queue.enqueue(capture)
    print("Queued: \(queued)")
    try? await Task.sleep(nanoseconds: 20_000_000_000)  // allow encode+verify (speed 0)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    print("Staging contents: \(files)")
    for f in files {
      let path = staging.appendingPathComponent(f).path
      if FileManager.default.fileExists(atPath: "\(path)/journal.json") {
        let data = try? Data(contentsOf: URL(fileURLWithPath: "\(path)/journal.json"))
        print("Journal: \(String(data: data ?? Data(), encoding: .utf8) ?? "-")")
      }
    }
    print("=== END-TO-END DONE ===")
    exit(0)
  }
}

final class FrameCollector: FrameSink, @unchecked Sendable {
  // Narrow documented exception: collector forwards to an actor immediately.
  private let store = FrameStore()

  func receive(_ frame: DeliveredFrame) {
    Task {
      await store.store(frame)
      let isCurrent = await store.isCurrentGeneration(frame)
      _ = await store.recordAndEvaluate(
        generation: frame.generation, isStale: !isCurrent,
        adjusting: false, monotonicNanos: DispatchTime.now().uptimeNanoseconds)
    }
  }

  func newestFreshFrame(timeoutNanos: UInt64) async -> DeliveredFrame? {
    await store.newestFreshFrame(timeoutNanos: timeoutNanos)
  }

  func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    await store.snapshotMetadata(for: frame)
  }
}
