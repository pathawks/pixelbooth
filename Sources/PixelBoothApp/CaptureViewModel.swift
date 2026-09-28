// CaptureViewModel — presentation state for the capture window.
// Stream configuration and blocking session operations happen off the main
// actor; the VM only reflects state snapshots.

import Foundation
import AVFoundation
import SwiftUI
import CoreMedia
import PixelBoothCore
import PixelBoothCapture
import PixelBoothLibrary
import PixelBoothMetadata

/// Receives frames on the capture queue (not main-actor isolated).
final class FrameIngest: FrameSink, @unchecked Sendable {
  // @unchecked Sendable is a narrow, documented exception: `weakVM` is only
  // touched from the capture queue via a lock, and work is dispatched to
  // detached tasks immediately.
  private let lock = NSLock()
  private weak var weakVM: CaptureViewModel?
  private let store = FrameStore()

  func bind(_ vm: CaptureViewModel) {
    lock.lock(); defer { lock.unlock() }
    weakVM = vm
  }

  func receive(_ frame: DeliveredFrame) {
    let store = store
    Task {
      await store.store(frame)
      let isFresh = await store.freshFrameAvailable()
      let state = await readinessState(frame: frame, store: store)
      await weakVM?.frameArrived(
        generation: frame.generation,
        freshnessText: CaptureViewModel.readinessDescription(state),
        fresh: isFresh)
    }
  }

  private func readinessState(frame: DeliveredFrame, store: FrameStore) async -> ReadinessState {
    // macOS AVFoundation does not expose per-frame adjustment indicators on
    // most UVC cameras; the readiness heuristic is used and is labeled as
    // heuristic in the UI.
    let monotonic = DispatchTime.now().uptimeNanoseconds
    let current = await store.isCurrentGeneration(frame)
    return await store.recordAndEvaluate(
      generation: frame.generation, isStale: !current,
      adjusting: false, monotonicNanos: monotonic)
  }

  func newestFreshFrame(timeoutNanos: UInt64) async -> DeliveredFrame? {
    await store.newestFreshFrame(timeoutNanos: timeoutNanos)
  }

  func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    await store.snapshotMetadata(for: frame)
  }
}

@MainActor
final class CaptureViewModel: ObservableObject {
  @Published var cameras: [CameraDevice] = []
  @Published var availableModes: [CaptureFormat] = []
  @Published var selectedCameraID: String? {
    didSet { Task { await cameraSelectionChanged() } }
  }
  @Published var selectedModeID: String? {
    didSet { Task { await modeSelectionChanged() } }
  }
  @Published var readinessText: String = "No stream"
  @Published var pendingSaveText: String = "No pending captures"
  @Published var lastResultText: String?
  @Published var shutterEnabled = false

  let ingest = FrameIngest()
  private var service = CaptureService()
  private var discovery = CaptureDiscovery()

  init() {
    ingest.bind(self)
  }

  func activate() {
    Task {
      await discover()
      await startStreaming()
      await service.addSink(ingest, queue: DispatchQueue(label: "app.pixelbooth.framesink"))
      await service.publishGeneration()
    }
  }

  func deactivate() {
    Task {
      await service.stop()
    }
  }

  func discover() async {
    cameras = await discovery.discoverCameras()
    if selectedCameraID == nil {
      selectedCameraID = cameras.first?.uniqueID
    }
  }

  func startStreaming() async {
    await reconfigure()
  }

  func cameraSelectionChanged() async {
    guard let id = selectedCameraID else { return }
    guard let device = AVCaptureDevice(uniqueID: id) else {
      // A remembered camera that disappeared: explain and require selection.
      readinessText = "Camera unavailable — select another camera"
      shutterEnabled = false
      return
    }
    let modes = deviceModes(device)
    availableModes = modes.map { $0.asCaptureFormat }
    if selectedModeID == nil ||
        !availableModes.contains(where: { $0.descriptiveLabel == selectedModeID }) {
      selectedModeID = ModeSelector.preferredMode(modes)?.asCaptureFormat.descriptiveLabel
    }
  }

  func modeSelectionChanged() async {
    await reconfigure()
  }

  private func deviceModes(_ device: AVCaptureDevice) -> [CameraMode] {
    device.formats.map { fmt in
      let desc = fmt.formatDescription
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      let fourCC = CMFormatDescriptionGetMediaSubType(desc)
      var minRate = 0.0, maxRate = 0.0
      if let range = fmt.videoSupportedFrameRateRanges.first {
        minRate = 1.0 / range.maxFrameDuration.seconds
        maxRate = 1.0 / range.minFrameDuration.seconds
      }
      let probe = CaptureFormat(width: Int(dims.width), height: Int(dims.height), fourCC: fourCC)
      return CameraMode(
        deviceID: device.uniqueID, formatID: nil, mediaSubType: fourCC,
        dimensions: (Int(dims.width), Int(dims.height)),
        minFrameRate: minRate, maxFrameRate: maxRate, pixelFormat: fourCC,
        bitsPerChannel: ModeSelector.bitsPerChannel(of: probe),
        chromaSampling: ModeSelector.chromaSampling(of: probe),
        yuvRange: nil)
    }
  }

  func reconfigure() async {
    guard let id = selectedCameraID, let device = AVCaptureDevice(uniqueID: id) else { return }
    guard let label = selectedModeID,
          let mode = availableModes.first(where: { $0.descriptiveLabel == label }) else { return }
    let cameraMode = CameraMode(
      deviceID: device.uniqueID, formatID: nil, mediaSubType: mode.fourCC,
      dimensions: (mode.width, mode.height), minFrameRate: 0,
      maxFrameRate: mode.maxFrameRate, pixelFormat: mode.fourCC)
    do {
      try await service.configure(deviceUniqueID: id, mode: cameraMode)
      try await service.start()
      await service.publishGeneration()
    } catch {
      readinessText = "Capture configuration failed: \(error)"
      shutterEnabled = false
    }
  }

  /// Attach the preview view so the session renders into it (display only).
  func attachPreview(_ view: PreviewPreviewView) async {
    let session = await service.sessionForPreview()
    if let session {
      view.attach(session: session)
    }
  }

  /// Public shutter entry point for the UI. Applies the optional countdown;
  /// countdown completion is the shutter event.
  func requestCapture() {
    let countdown = UserDefaults.standard.double(forKey: "countdownSeconds")
    Task {
      if countdown > 0 {
        let steps = Int(countdown * 10)
        for step in 0..<steps {
          readinessText = String(format: "Capturing in %.1f s…", countdown - Double(step) / 10)
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
      }
      await handleShutter()
    }
  }

  func handleShutter() async {
    // At the shutter event, select the newest complete, sufficiently fresh
    // frame already available; if stale, wait for a fresh frame within a
    // bounded timeout.
    guard let frame = await ingest.newestFreshFrame(timeoutNanos: 250_000_000) else {
      lastResultText = "No fresh frame available"
      return
    }
    let snapshot = await ingest.snapshotMetadata(for: frame)
    let capture: CapturedCapture
    do {
      capture = try CapturedCapture(from: frame, metadata: snapshot)
    } catch {
      lastResultText = "Capture rejected: unsupported representation"
      return
    }
    let queued = await SaveQueueHolder.shared.queue.enqueue(capture)
    lastResultText = queued ? "Capture queued (\(capture.uuid.uuidString.prefix(8)))" : "Capture refused (capacity)"
  }

  // Called from FrameIngest on a detached task; hops to main actor.
  func frameArrived(generation gen: Int, freshnessText: String, fresh: Bool) {
    readinessText = freshnessText
    shutterEnabled = fresh
  }

  static func readinessDescription(_ state: ReadinessState) -> String {
    switch state {
    case .noStream:
      return "No stream"
    case .warmingUp(let framesNeeded, let ms, let adjusting):
      var s = "Warming up (heuristic): \(ms) ms"
      if framesNeeded > 0 { s += ", \(framesNeeded) frames needed" }
      if adjusting { s += ", still adjusting" }
      return s
    case .ready:
      return "Ready"
    case .stillAdjusting(let ms):
      return "Still adjusting (\(ms) ms) — capture override available"
    }
  }
}
