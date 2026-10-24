// CaptureViewModel — presentation state for the capture window.
// Stream configuration and blocking session operations happen off the main
// actor; the VM only reflects state snapshots.

import AVFoundation
import CoreMedia
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import PixelBoothMetadata
import SwiftUI
import os

enum CaptureWindowStatus: Equatable {
  case permissionDenied
  case noCamera
  case noSupportedMode
  case connecting
  case ready
  case disconnected
  case failed(String)
}

/// Receives frames on the capture queue (not main-actor isolated).
final class FrameIngest: FrameSink, @unchecked Sendable {
  // @unchecked Sendable is a narrow, documented exception: `weakVM` is only
  // touched via the coalescer lock, and work is dispatched to detached tasks
  // immediately.
  private weak var weakVM: CaptureViewModel?
  private let store = FrameStore()
  private let latestFrameMailbox = FrameAdmissionMailbox<DeliveredFrame>(
    policy: .latest(maximumBytes: 128 * 1024 * 1024))
  private let dependentFrameMailbox = FrameAdmissionMailbox<DeliveredFrame>(
    policy: .dependencyPreserving(maximumFrames: 16, maximumBytes: 64 * 1024 * 1024))
  private let processingQueue = DispatchQueue(
    label: "app.pixelbooth.frame-ingest", qos: .userInteractive)
  private let h264Decoder = H264VideoToolboxStreamDecoder()
  // Coalescer: publish UI state only when it actually changes, at most
  // ~4 Hz. Per-frame publication re-rendered the whole window at frame
  // rate and re-entered AppKit event routing mid-layout (crash trigger).
  private let coalescer = OSAllocatedUnfairLock<CoalescedState>(
    initialState: CoalescedState())

  private struct CoalescedState {
    var lastState: ReadinessState?
    var lastFresh: Bool?
    var lastFormatError: String?
    var lastPublishNanos: UInt64 = 0
    /// The configuration whose frames may publish readiness. Reconfiguration
    /// advances it so a callback queued under the previous configuration
    /// cannot republish state after the reset.
    var generation: Int?
    var deviceID: String?
    var expectedFormat: CaptureFormat?
  }

  func bind(_ vm: CaptureViewModel) {
    coalescer.withLock { _ in weakVM = vm }
  }

  func receive(_ frame: DeliveredFrame) {
    if frame.sourceFourCC != PixelFormatFourCC.avc1 {
      let result = latestFrameMailbox.offer(frame, byteCount: frame.retainedByteCount)
      if result.shouldScheduleDrain {
        processingQueue.async { [weak self] in
          self?.drainLatestFrames()
        }
      }
      return
    }
    if CMSampleBufferGetImageBuffer(frame.sampleBuffer) != nil {
      processSerially(frame)
      return
    }
    let result = dependentFrameMailbox.offer(
      frame, byteCount: frame.retainedByteCount,
      isRandomAccessFrame: frame.isRandomAccessFrame)
    if result.shouldScheduleDrain {
      processingQueue.async { [weak self] in self?.drainDependentFrames() }
    }
  }

  /// Processes only the latest pending independently decodable frame. Every
  /// frame still enters the store and readiness policy with its original
  /// buffer; only frames superseded before processing are discarded.
  private func drainLatestFrames() {
    while let delivery = latestFrameMailbox.takeNext() {
      processSerially(delivery.value)
    }
  }

  private func drainDependentFrames() {
    while let delivery = dependentFrameMailbox.takeNext() {
      var frame = delivery.value
      frame.requiresDecoderReset = frame.requiresDecoderReset || delivery.requiresDecoderReset
      guard isCurrent(frame) else { continue }
      if frame.requiresDecoderReset { h264Decoder.invalidate() }
      do {
        for output in try h264Decoder.decode(frame) {
          guard let decodedFrame = makeDecodedFrame(output) else {
            publishDecodeError(frame, "VideoToolbox returned an invalid image buffer")
            continue
          }
          processSerially(decodedFrame)
        }
      } catch {
        publishDecodeError(frame, error.localizedDescription)
      }
    }
  }

  private func isCurrent(_ frame: DeliveredFrame) -> Bool {
    coalescer.withLock { state in
      state.generation == frame.generation && state.deviceID == frame.deviceUniqueID
    }
  }

  private func processSerially(_ frame: DeliveredFrame) {
    let completion = DispatchSemaphore(value: 0)
    Task {
      await process(frame)
      completion.signal()
    }
    completion.wait()
  }

  private func makeDecodedFrame(_ output: H264VideoToolboxStreamDecoder.DecodedOutput)
    -> DeliveredFrame?
  {
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: output.pixelBuffer,
        formatDescriptionOut: &format) == noErr,
      let format
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: output.duration, presentationTimeStamp: output.presentationTimeStamp,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: output.pixelBuffer,
        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    let source = output.sourceFrame
    let pts = output.presentationTimeStamp
    let timestampNanos: UInt64 = {
      guard pts.isNumeric else { return source.timestampNanos }
      let seconds = CMTimeGetSeconds(pts)
      return seconds >= 0 ? UInt64(seconds * 1_000_000_000) : source.timestampNanos
    }()
    let decodedFrame = DeliveredFrame(
      sampleBuffer: sample, generation: source.generation,
      deviceUniqueID: source.deviceUniqueID,
      fourCC: CVPixelBufferGetPixelFormatType(output.pixelBuffer),
      width: CVPixelBufferGetWidth(output.pixelBuffer),
      height: CVPixelBufferGetHeight(output.pixelBuffer),
      timestampNanos: timestampNanos,
      hostMonotonicNanos: source.hostMonotonicNanos,
      hostWallClockISO: source.hostWallClockISO,
      sourceFourCC: source.sourceFourCC,
      sourceSampleBuffer: source.sourceSampleBuffer ?? source.sampleBuffer)
    CMIOFrameBox.shared.store(output.pixelBuffer, from: source)
    return decodedFrame
  }

  private func publishDecodeError(_ frame: DeliveredFrame, _ message: String) {
    let publish = coalescer.withLock { state -> CaptureViewModel? in
      guard state.generation == frame.generation, state.deviceID == frame.deviceUniqueID,
        state.lastFormatError != message
      else { return nil }
      state.lastFormatError = message
      state.lastFresh = false
      state.lastPublishNanos = DispatchTime.now().uptimeNanoseconds
      return weakVM
    }
    guard let publish else { return }
    Task { @MainActor [weak publish] in
      publish?.frameDecodeFailed(frame: frame, message: message)
    }
  }

  private func process(_ frame: DeliveredFrame) async {
    let configuration = coalescer.withLock { state -> (Int, String, CaptureFormat)? in
      guard let generation = state.generation, let deviceID = state.deviceID,
        let expected = state.expectedFormat
      else {
        return nil
      }
      return (generation, deviceID, expected)
    }
    guard let configuration else { return }
    do {
      try FrameExtraction.validateProgressiveFrame(
        sampleBuffer: frame.sampleBuffer, sourceSampleBuffer: frame.sourceSampleBuffer)
    } catch {
      publishFieldMetadataFailure(frame, message: error.localizedDescription)
      return
    }
    guard await store.store(frame) else { return }
    let formatError: String? = {
      var deliveredFourCC = frame.fourCC
      var width = frame.width
      var height = frame.height
      if let pixel = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
        deliveredFourCC = CVPixelBufferGetPixelFormatType(pixel)
        width = CVPixelBufferGetWidth(pixel)
        height = CVPixelBufferGetHeight(pixel)
      }
      let delivered = CaptureFormat(width: width, height: height, fourCC: deliveredFourCC)
      do {
        _ = try AcquisitionPolicy.evaluate(
          deviceUniqueID: frame.deviceUniqueID, generation: frame.generation,
          expectedDeviceID: configuration.1, expectedGeneration: configuration.0,
          selected: configuration.2, delivered: delivered)
        return nil
      } catch {
        return error.localizedDescription
      }
    }()
    let isFresh: Bool
    if formatError == nil {
      isFresh = await store.freshFrameAvailable()
    } else {
      isFresh = false
    }
    // Readiness is recorded only while the frame still belongs to the active
    // configuration; an obsolete callback returns nil here. macOS
    // AVFoundation does not expose per-frame adjustment indicators on most
    // UVC cameras, so the explicitly labeled heuristic runs with
    // `adjusting: false`.
    let readiness: ReadinessState
    if formatError == nil {
      guard let state = await store.recordAndEvaluate(frame: frame, adjusting: false) else {
        return
      }
      readiness = state
    } else {
      readiness = await store.currentReadiness()
    }
    // Capture the weak VM under the lock; the hop itself happens after.
    let shouldPublish: (vm: CaptureViewModel?, text: String, fresh: Bool, formatError: String?)? =
      coalescer.withLock { c in
        // A frame queued before reconfiguration must not republish readiness
        // for the configuration that replaced it.
        guard c.generation == frame.generation else { return nil }
        let changed =
          c.lastState != readiness || c.lastFresh != isFresh
          || c.lastFormatError != formatError
        let now = DispatchTime.now().uptimeNanoseconds
        let due = now &- c.lastPublishNanos > 250_000_000
        guard changed || due else { return nil }
        c.lastState = readiness
        c.lastFresh = isFresh
        c.lastFormatError = formatError
        c.lastPublishNanos = now
        return (weakVM, CaptureViewModel.readinessDescription(readiness), isFresh, formatError)
      }
    guard let vm = shouldPublish?.vm else { return }
    await vm.frameArrived(
      frame: frame,
      freshnessText: shouldPublish!.text,
      readiness: readiness,
      fresh: shouldPublish!.fresh,
      formatError: shouldPublish!.formatError)
  }

  private func publishFieldMetadataFailure(_ frame: DeliveredFrame, message: String) {
    let target = coalescer.withLock { state -> CaptureViewModel? in
      guard state.generation == frame.generation, state.deviceID == frame.deviceUniqueID else {
        return nil
      }
      state.lastFormatError = message
      state.lastFresh = false
      state.lastPublishNanos = DispatchTime.now().uptimeNanoseconds
      return weakVM
    }
    guard let target else { return }
    Task { @MainActor [weak target] in
      target?.frameFormatRejected(frame: frame, message: message)
    }
  }

  func newestFreshFrame(timeoutNanos: UInt64) async -> DeliveredFrame? {
    await store.newestFreshFrame(timeoutNanos: timeoutNanos)
  }

  func frameRates() async -> (requested: Double, measured: Double) {
    let requested = await store.requestedFrameRate
    let measured = await store.measuredFrameRate
    return (requested, measured)
  }

  /// Reset coalesced publishing and advance the configuration whose frames may
  /// publish. Set before the store's configuration so a frame cannot publish
  /// between the two.
  private func resetPublishing(
    generation: Int?, deviceID: String? = nil, expectedFormat: CaptureFormat? = nil
  ) {
    coalescer.withLock {
      $0.generation = generation
      $0.deviceID = deviceID
      $0.expectedFormat = expectedFormat
      $0.lastFresh = false
      $0.lastState = .noStream
      $0.lastFormatError = nil
      $0.lastPublishNanos = 0
    }
  }

  func beginConfiguration(
    deviceID: String, generation: Int, frameIntervalNanos: UInt64,
    expectedFormat: CaptureFormat
  ) async {
    resetPublishing(
      generation: generation, deviceID: deviceID, expectedFormat: expectedFormat)
    latestFrameMailbox.reset()
    dependentFrameMailbox.reset()
    processingQueue.async { [h264Decoder] in h264Decoder.invalidate() }
    await store.beginConfiguration(
      deviceID: deviceID, generation: generation,
      frameIntervalNanos: frameIntervalNanos)
  }

  /// Drop retained frames and stop publishing readiness for the previous
  /// configuration. Called before reconfiguring so delayed callbacks from the
  /// old stream cannot enter (or republish state for) the replacement.
  func invalidateConfiguration() async {
    resetPublishing(generation: nil)
    latestFrameMailbox.reset()
    dependentFrameMailbox.reset()
    processingQueue.async { [h264Decoder] in h264Decoder.invalidate() }
    await store.invalidate()
  }

  /// Drop retained frames for the stopping stream and reset coalesced
  /// readiness publishing. A delayed stop for an already-replaced stream is
  /// ignored by the store, so the window is not told to shut down either.
  func streamStopped(_ stop: StreamStop) {
    let ingest = self
    Task {
      guard
        await store.invalidateIfActive(
          deviceID: stop.deviceUniqueID, generation: stop.generation)
      else { return }
      ingest.resetPublishing(generation: nil)
      ingest.latestFrameMailbox.reset()
      ingest.dependentFrameMailbox.reset()
      ingest.processingQueue.async { [h264Decoder = ingest.h264Decoder] in
        h264Decoder.invalidate()
      }
      guard let vm = ingest.coalescer.withLock({ _ in ingest.weakVM }) else { return }
      await vm.streamStopped(
        reason: stop.reason,
        deviceID: stop.deviceUniqueID,
        generation: stop.generation)
    }
  }

  func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    await store.snapshotMetadata(for: frame)
  }

  func setReadinessHeuristic(_ heuristic: ReadinessHeuristic) async {
    await store.setReadinessHeuristic(heuristic)
  }
}

@MainActor
final class CaptureCommandMenuState: ObservableObject {
  static let shared = CaptureCommandMenuState()

  @Published private(set) var cameras: [CameraDevice] = []
  @Published private(set) var availableModes: [CameraMode] = []
  @Published private(set) var cameraAccessDenied = false
  @Published private(set) var selectedCameraID: String?
  @Published private(set) var selectedModeID: String?
  @Published private(set) var shutterEnabled = false

  func update(from viewModel: CaptureViewModel) {
    cameras = viewModel.cameras
    availableModes = viewModel.availableModes
    cameraAccessDenied = viewModel.cameraAccessDenied
    selectedCameraID = viewModel.selectedCameraID
    selectedModeID = viewModel.selectedModeID
    shutterEnabled = viewModel.shutterEnabled
  }

  func updateShutterEnabled(_ enabled: Bool) {
    guard shutterEnabled != enabled else { return }
    shutterEnabled = enabled
  }
}

@MainActor
final class CaptureViewModel: ObservableObject {
  static let shared = CaptureViewModel()

  @Published var cameras: [CameraDevice] = [] {
    didSet { updateCommandMenuState() }
  }
  @Published var availableModes: [CameraMode] = [] {
    didSet { updateCommandMenuState() }
  }
  @Published private(set) var cameraAccessDenied = false {
    didSet { updateCommandMenuState() }
  }
  @Published private(set) var cameraWindowStatus: CaptureWindowStatus = .connecting
  @Published var acquisitionStatus = "Acquisition fidelity unknown"
  @Published var selectedCameraID: String? {
    didSet {
      guard oldValue != selectedCameraID else { return }
      updateCommandMenuState()
      if let oldValue, let selectedModeID {
        UserDefaults.standard.set(selectedModeID, forKey: Self.rememberedModeKey(for: oldValue))
      }
      invalidateActiveMode()
      guard windowActive, !suppressSelectionReconfiguration else { return }
      Task { await cameraSelectionChanged() }
    }
  }
  @Published var selectedModeID: String? {
    didSet {
      guard oldValue != selectedModeID else { return }
      updateCommandMenuState()
      if let selectedCameraID, let selectedModeID {
        UserDefaults.standard.set(
          selectedModeID, forKey: Self.rememberedModeKey(for: selectedCameraID))
      }
      invalidateActiveMode()
      guard windowActive, !suppressSelectionReconfiguration else { return }
      Task { await modeSelectionChanged() }
    }
  }
  @Published var readinessText: String = "No stream"
  @Published var pendingSaveText: String = "No pending captures"
  @Published private(set) var configuredFrameRate: Double?
  @Published var lastResultText: String?
  @Published var shutterEnabled = false {
    didSet {
      guard oldValue != shutterEnabled else { return }
      CaptureCommandMenuState.shared.updateShutterEnabled(shutterEnabled)
    }
  }
  @Published private(set) var captureEligibility: CaptureEligibilityDecision =
    .waitingForReadiness(.noStream)
  @Published private(set) var countdownRemaining: Int?

  let ingest = FrameIngest()
  /// CoreMediaIO backend: full mode selection without AVFoundation's stream
  /// pinning (macOS 27 pins device streams to their default; TN3121 finding 4).
  private let cmioService = CMIOCaptureService()
  private let cmioPreviewSink = CMIOFrameBoxSink()
  /// AVFoundation backend, used when the CMIO path is unestablishable.
  private var service = CaptureService()
  private var discovery = CaptureDiscovery()
  private let backendOperationGate = CaptureBackendOperationGate()
  private let configurationToken = CaptureConfigurationToken()
  enum Backend: String { case cmio, avfoundation }
  private(set) var activeBackend: Backend?
  private var activeMode: CaptureFormat?
  private var activeDeviceID: String?
  private var activeGeneration: Int?
  /// Best-effort classification of the delivered format, reported in the
  /// status line. Informational only — it never gates the shutter.
  @Published private(set) var currentEvidence: AcquisitionEvidence?
  private var configurationRevision = 0
  private var cameraEnumerationRevision = 0
  private var windowActive = false
  private var suppressSelectionReconfiguration = false
  private var readinessState: ReadinessState = .noStream
  private var latestFrameIsFresh = false
  private var latestFormatIsValid = false
  private var eligibilityState = CaptureEligibilityState()
  private var countdownTask: Task<Void, Never>?
  private let locationProvider = LocationProvider()
  private var locationPreferencesObserver: NSObjectProtocol?
  private var readinessPreferencesObserver: NSObjectProtocol?
  private var frameRatePreferencesObserver: NSObjectProtocol?

  private func invalidateActiveMode() {
    _ = advanceConfigurationRevision()
    clearActiveConfigurationState()
    acquisitionStatus = "Waiting for selected mode"
  }

  private func advanceConfigurationRevision() -> Int {
    configurationRevision += 1
    configurationToken.publish(configurationRevision)
    return configurationRevision
  }

  private func clearActiveConfigurationState() {
    activeDeviceID = nil
    activeGeneration = nil
    activeMode = nil
    configuredFrameRate = nil
    activeBackend = nil
    currentEvidence = nil
    shutterEnabled = false
    latestFrameIsFresh = false
    latestFormatIsValid = false
    readinessState = .noStream
    eligibilityState.selectConfiguration(nil)
    captureEligibility = .waitingForReadiness(.noStream)
    cancelCountdown()
    CMIOFrameBox.shared.clear()
  }

  private static func rememberedModeKey(for deviceID: String) -> String {
    "pixelbooth.selectedMode.\(deviceID)"
  }

  var hasActiveMode: Bool { activeMode != nil }

  var selectedMode: CameraMode? {
    availableModes.first { $0.id == selectedModeID }
  }

  var canOverrideAdjustment: Bool {
    if case .stillAdjusting = readinessState { return true }
    return false
  }

  func refreshCameras() {
    Task {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .notDetermined:
        activate()
        return
      case .denied, .restricted:
        cameraAccessDenied = true
        cameraWindowStatus = .permissionDenied
        readinessText = "Camera permission denied — allow in System Settings"
        return
      default:
        cameraAccessDenied = false
      }
      await discover()
      guard windowActive else { return }
      await cameraSelectionChanged()
    }
  }

  init() {
    ingest.bind(self)
    installPreferenceObservers()
    updateCommandMenuState()
  }

  private func updateCommandMenuState() {
    CaptureCommandMenuState.shared.update(from: self)
  }

  private func installPreferenceObservers() {
    if locationPreferencesObserver == nil {
      locationPreferencesObserver = NotificationCenter.default.addObserver(
        forName: .pixelBoothLocationPreferencesChanged, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.applyLocationPreferences() }
      }
    }
    if readinessPreferencesObserver == nil {
      readinessPreferencesObserver = NotificationCenter.default.addObserver(
        forName: .pixelBoothReadinessPreferencesChanged, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.applyReadinessPreferences() }
      }
    }
    if frameRatePreferencesObserver == nil {
      frameRatePreferencesObserver = NotificationCenter.default.addObserver(
        forName: .pixelBoothFrameRatePreferencesChanged, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.windowActive else { return }
          await self.reconfigure()
        }
      }
    }
  }

  private func removePreferenceObservers() {
    if let locationPreferencesObserver {
      NotificationCenter.default.removeObserver(locationPreferencesObserver)
      self.locationPreferencesObserver = nil
    }
    if let readinessPreferencesObserver {
      NotificationCenter.default.removeObserver(readinessPreferencesObserver)
      self.readinessPreferencesObserver = nil
    }
    if let frameRatePreferencesObserver {
      NotificationCenter.default.removeObserver(frameRatePreferencesObserver)
      self.frameRatePreferencesObserver = nil
    }
  }

  func activate() {
    guard !windowActive else { return }
    windowActive = true
    cameraWindowStatus = .connecting
    installPreferenceObservers()
    Task {
      // Explicit permission flow: prompt once, and report denial honestly
      // instead of configuring a session that cannot run (a state where
      // macOS 27 throws on preview-connection writes).
      let status = AVCaptureDevice.authorizationStatus(for: .video)
      switch status {
      case .notDetermined:
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
          cameraAccessDenied = true
          cameraWindowStatus = .permissionDenied
          readinessText = "Camera permission denied — allow in System Settings"
          return
        }
      case .denied, .restricted:
        cameraAccessDenied = true
        cameraWindowStatus = .permissionDenied
        readinessText = "Camera permission denied — allow in System Settings"
        return
      default:
        cameraAccessDenied = false
        break
      }
      guard windowActive else { return }
      applyLocationPreferences()
      applyReadinessPreferences()
      await discover()
      guard windowActive else { return }
      await backendOperationGate.withExclusive {
        // Discovering the first camera can advance configurationRevision when
        // it selects the default device. Sink registration is independent of
        // that selection revision: skipping it leaves a running stream with no
        // frame or preview recipients.
        guard self.windowActive else { return }
        await self.service.addSink(
          self.ingest, queue: DispatchQueue(label: "app.pixelbooth.framesink"))
        guard self.windowActive else { return }
        await self.cmioService.addSink(
          self.ingest, queue: DispatchQueue(label: "app.pixelbooth.cmio.framesink"))
        guard self.windowActive else { return }
        await self.cmioService.addSink(
          self.cmioPreviewSink,
          queue: DispatchQueue(label: "app.pixelbooth.cmio.preview"))
      }
      await cameraSelectionChanged()
      guard windowActive else { return }
    }
  }

  func deactivate() {
    windowActive = false
    cameraEnumerationRevision += 1
    cancelCountdown()
    removePreferenceObservers()
    invalidateActiveMode()
    let stopRevision = configurationRevision
    locationProvider.setEnabled(false, maximumAgeSeconds: locationMaximumAgePreference)
    Task {
      await backendOperationGate.withExclusive {
        guard self.configurationRevision == stopRevision else { return }
        await self.service.removeSink(self.ingest)
        await self.cmioService.removeSink(self.ingest)
        await self.service.removeSink(self.cmioPreviewSink)
        await self.cmioService.removeSink(self.cmioPreviewSink)
        await self.service.stop()
        await self.cmioService.stop()
      }
    }
  }

  private var includeLocationPreference: Bool {
    UserDefaults.standard.object(forKey: "includeLocation") as? Bool ?? true
  }

  private var locationMaximumAgePreference: Double {
    let value = UserDefaults.standard.object(forKey: "locationMaximumAge") as? Double ?? 60
    return value.isFinite ? min(max(value, 10), 600) : 60
  }

  private func applyLocationPreferences() {
    guard windowActive else { return }
    locationProvider.setEnabled(
      includeLocationPreference,
      maximumAgeSeconds: locationMaximumAgePreference)
  }

  private func applyReadinessPreferences() {
    let defaults = UserDefaults.standard
    let heuristic = ReadinessHeuristic(
      minimumFreshFrames: min(
        max(
          defaults.integer(forKey: "minimumFreshFrames") == 0
            ? 8 : defaults.integer(forKey: "minimumFreshFrames"), 1), 60),
      minimumMillisecondsSinceValidStart: min(
        max(
          defaults.integer(forKey: "minimumMillisecondsSinceValidStart") == 0
            ? 500 : defaults.integer(forKey: "minimumMillisecondsSinceValidStart"), 100), 5000),
      maximumAdjustingWaitMilliseconds: min(
        max(
          defaults.integer(forKey: "maximumAdjustingWaitMilliseconds") == 0
            ? 5000 : defaults.integer(forKey: "maximumAdjustingWaitMilliseconds"), 1000), 20_000))
    Task { await ingest.setReadinessHeuristic(heuristic) }
  }

  /// Delivery stopped outside the shutter path (stop, disconnect, runtime
  /// error): invalidate the active mode so the shutter cannot select a frame
  /// from a dead stream, and explain the state. No automatic camera
  /// activation after a disconnect. A stop reported for a stream that has
  /// already been replaced is ignored.
  func streamStopped(reason: StreamStopReason, deviceID: String?, generation: Int?) {
    guard windowActive else { return }
    // Only a stop for the stream the window currently believes is active may
    // change the UI; an already-invalidated window stays as it is.
    guard let activeDeviceID, let activeGeneration else { return }
    if let deviceID, deviceID != activeDeviceID { return }
    if let generation, generation != activeGeneration { return }
    invalidateActiveMode()
    switch reason {
    case .stopped:
      cameraWindowStatus = .connecting
      readinessText = "No stream"
    case .deviceDisconnected:
      cameraWindowStatus = .disconnected
      readinessText = "Camera disconnected — select another camera"
      Task { await discover() }
    case .runtimeError(let message):
      cameraWindowStatus = .failed(message)
      readinessText = "Capture stopped: \(message)"
    }
  }

  func discover() async {
    cameras = await discovery.discoverCameras()
    if cameras.isEmpty {
      cameraWindowStatus = .noCamera
    } else if cameraWindowStatus == .noCamera {
      cameraWindowStatus = .connecting
    }
    if selectedCameraID == nil {
      updateSelectionWithoutReconfiguring {
        selectedCameraID = cameras.first?.uniqueID
      }
    }
  }

  func startStreaming() async {
    await reconfigure()
  }

  func cameraSelectionChanged() async {
    cameraEnumerationRevision += 1
    let request: CameraEnumerationRequest
    guard let id = selectedCameraID else {
      // No device selected: never leave the previous camera's stream attached
      // under a picker that no longer shows it.
      await reconfigure()
      return
    }
    request = CameraEnumerationRequest(deviceID: id, revision: cameraEnumerationRevision)
    guard let device = AVCaptureDevice(uniqueID: id) else {
      // A remembered camera that disappeared: explain and require selection.
      readinessText = "Camera unavailable — select another camera"
      shutterEnabled = false
      await reconfigure()
      return
    }
    // Prefer the CMIO mode list: it is what the CMIO backend can actually
    // select, and it includes modes AVFoundation pins away (e.g. the built-in
    // camera's 1552×1552 square stream on macOS 27). Enumeration hops off the
    // main actor; it touches the HAL over IPC.
    let cmioModes = await Task.detached(priority: .userInitiated) {
      CMIOCaptureDiscovery.modes(deviceUID: id)
    }.value
    guard
      request.mayPublish(
        selectedDeviceID: selectedCameraID,
        currentRevision: cameraEnumerationRevision,
        windowActive: windowActive,
        deviceConnected: device.isConnected)
    else {
      if selectedCameraID == id, windowActive, !device.isConnected {
        availableModes = []
        updateSelectionWithoutReconfiguring { selectedModeID = nil }
        readinessText = "Camera unavailable — select another camera"
        await reconfigure()
      }
      return
    }
    let modes = cmioModes.isEmpty ? deviceModes(device) : cmioModes
    availableModes = modes
    updateSelectionWithoutReconfiguring {
      if let rememberedModeID = UserDefaults.standard.string(
        forKey: Self.rememberedModeKey(for: id))
      {
        if let rememberedMode = ModeSelector.rememberedMode(
          id: rememberedModeID, in: availableModes)
        {
          selectedModeID = rememberedMode.id
          if rememberedMode.id != rememberedModeID {
            UserDefaults.standard.set(
              rememberedMode.id, forKey: Self.rememberedModeKey(for: id))
          }
        } else {
          selectedModeID = nil
          readinessText = "Remembered mode is unavailable — choose a mode again"
        }
      } else if selectedModeID == nil
        || !availableModes.contains(where: { $0.id == selectedModeID })
      {
        selectedModeID = ModeSelector.preferredMode(modes)?.id
      }
    }
    // A camera change always reconfigures: the new device is configured
    // independently of the mode-selection observer, so a mode identity that
    // happens to match across devices — or the absence of a selectable mode —
    // can never leave the capture session on the previous camera.
    await reconfigure()
  }

  private func updateSelectionWithoutReconfiguring(_ update: () -> Void) {
    let wasSuppressed = suppressSelectionReconfiguration
    suppressSelectionReconfiguration = true
    defer { suppressSelectionReconfiguration = wasSuppressed }
    update()
  }

  func modeSelectionChanged() async {
    await reconfigure()
  }

  private func deviceModes(_ device: AVCaptureDevice) -> [CameraMode] {
    device.formats.enumerated().map { index, fmt in
      let desc = fmt.formatDescription
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      let fourCC = CMFormatDescriptionGetMediaSubType(desc)
      let supportedRanges = fmt.videoSupportedFrameRateRanges
      var minRate = 0.0
      var maxRate = 0.0
      if !supportedRanges.isEmpty {
        minRate = supportedRanges.map { 1.0 / $0.maxFrameDuration.seconds }.min() ?? 0
        maxRate = supportedRanges.map { 1.0 / $0.minFrameDuration.seconds }.max() ?? 0
      }
      let probe = CaptureFormatFacts.applying(
        to: CaptureFormat(width: Int(dims.width), height: Int(dims.height), fourCC: fourCC))
      return CameraMode(
        deviceID: device.uniqueID, formatID: String(index), mediaSubType: fourCC,
        dimensions: (Int(dims.width), Int(dims.height)),
        minFrameRate: minRate, maxFrameRate: maxRate, pixelFormat: fourCC,
        bitsPerChannel: probe.bitsPerChannel,
        chromaSampling: probe.chromaSampling,
        yuvRange: probe.yuvRange)
    }
  }

  func reconfigure() async {
    guard windowActive else { return }
    let revision = advanceConfigurationRevision()
    clearActiveConfigurationState()
    cameraWindowStatus = .connecting
    readinessText = "Starting camera"
    // Drop retained frames for the replaced stream before configuring the new
    // one: a callback already queued from the old stream must not survive the
    // reconfiguration, and until `beginConfiguration` below the store accepts
    // nothing at all.
    await ingest.invalidateConfiguration()
    guard revision == configurationRevision else { return }
    guard let id = selectedCameraID, AVCaptureDevice(uniqueID: id) != nil else {
      // Nothing configurable is selected: tear the previous stream down
      // instead of leaving a camera running that the picker no longer shows.
      await stopBothBackends(expectedRevision: revision)
      guard revision == configurationRevision else { return }
      cameraWindowStatus = cameras.isEmpty ? .noCamera : .disconnected
      return
    }
    guard let label = selectedModeID,
      let cameraMode = availableModes.first(where: { $0.id == label })
    else {
      await stopBothBackends(expectedRevision: revision)
      guard revision == configurationRevision else { return }
      cameraWindowStatus = .noSupportedMode
      readinessText =
        availableModes.isEmpty
        ? "This camera has no available capture modes"
        : "Choose an available camera mode from the Mode menu"
      return
    }
    do {
      shutterEnabled = false
      let rateOverride = UserDefaults.standard.double(forKey: "frameRateOverride")
      let requestedFrameRate =
        rateOverride > 0
        ? rateOverride : cameraMode.maxFrameRate > 0 ? cameraMode.maxFrameRate : nil
      let configurationGeneration = revision
      try await backendOperationGate.withExclusive {
        guard self.windowActive, revision == self.configurationRevision else { return }
        // Two clients reconfiguring the same device would fight. Keep stop,
        // negotiation, fallback and start in one serialized operation.
        await self.stopBothBackendsUnlocked()
        guard self.windowActive, revision == self.configurationRevision else { return }

        let backend: Backend
        let selectedFrameRate: Double?
        let configuredMode: CameraMode
        do {
          _ = try await self.cmioService.configure(
            deviceUniqueID: id, mode: cameraMode,
            requestedFrameRate: requestedFrameRate, generation: configurationGeneration,
            operationToken: self.configurationToken)
          guard self.windowActive, revision == self.configurationRevision else { return }
          selectedFrameRate = await self.cmioService.configuredFrameRate
          configuredMode = await self.cmioService.configuredMode ?? cameraMode
          guard self.windowActive, revision == self.configurationRevision else { return }
          backend = .cmio
        } catch {
          guard self.windowActive, revision == self.configurationRevision else { return }
          self.readinessText = "CMIO unavailable for this mode — using AVFoundation fallback"
          _ = try await self.service.configure(
            deviceUniqueID: id, mode: cameraMode,
            requestedFrameRate: requestedFrameRate, generation: configurationGeneration,
            operationToken: self.configurationToken)
          guard self.windowActive, revision == self.configurationRevision else { return }
          selectedFrameRate = await self.service.configuredFrameRate
          configuredMode = cameraMode
          guard self.windowActive, revision == self.configurationRevision else { return }
          backend = .avfoundation
        }

        guard self.windowActive, revision == self.configurationRevision else { return }
        self.activeBackend = backend
        self.configuredFrameRate = selectedFrameRate
        if let index = self.availableModes.firstIndex(where: { $0.id == configuredMode.id }) {
          self.availableModes[index] = configuredMode
        }
        self.activeMode = configuredMode.asCaptureFormat
        self.activeGeneration = configurationGeneration
        self.activeDeviceID = id
        CMIOFrameBox.shared.beginConfiguration(
          deviceID: id, generation: configurationGeneration)
        let frameIntervalNanos = selectedFrameRate.map { UInt64(1_000_000_000.0 / $0) } ?? 0
        await self.ingest.beginConfiguration(
          deviceID: id, generation: configurationGeneration,
          frameIntervalNanos: frameIntervalNanos,
          expectedFormat: configuredMode.asCaptureFormat)
        guard self.windowActive, revision == self.configurationRevision else { return }
        switch backend {
        case .cmio:
          try await self.cmioService.start(
            expectedGeneration: configurationGeneration,
            operationToken: self.configurationToken)
        case .avfoundation:
          try await self.service.start(
            expectedGeneration: configurationGeneration,
            operationToken: self.configurationToken)
        }
        guard self.windowActive, revision == self.configurationRevision else { return }
      }
    } catch {
      guard revision == configurationRevision else { return }
      // Configuration failed after the previous stream was detached. Capture
      // is already gated on freshness and frame identity (frames must match
      // the active device and generation), so no retained frame from the old
      // stream can satisfy the shutter.
      readinessText = "Capture configuration failed: \(error)"
      cameraWindowStatus = .failed(error.localizedDescription)
      shutterEnabled = false
    }
  }

  /// Stop whichever backends may hold a stream. Safe to call always.
  private func stopBothBackends(expectedRevision: Int? = nil) async {
    await backendOperationGate.withExclusive {
      guard expectedRevision == nil || expectedRevision == self.configurationRevision else {
        return
      }
      await self.stopBothBackendsUnlocked()
    }
  }

  private func stopBothBackendsUnlocked() async {
    await service.stop()
    await cmioService.stop()
  }

  /// Attach the preview view so the session renders into it (display only).
  /// The service exposes a cheap nonisolated static accessor; no actor hop.
  func attachPreview(_ view: PreviewPreviewView) {
    if let session = CaptureService.previewSession() {
      view.attach(session: session)
    }
  }

  private var activeConfigurationKey: String? {
    guard let activeDeviceID, let activeGeneration, let activeMode else { return nil }
    return
      "\(activeDeviceID)#\(activeGeneration)#\(activeMode.width)x\(activeMode.height)#\(activeMode.fourCC)#\(activeMode.bitsPerChannel ?? 0)#\(activeMode.chromaSampling?.rawValue ?? "unknown")#\(activeMode.yuvRange?.rawValue ?? "unknown")"
  }

  private func eligibilityScopeKey(for evidence: AcquisitionEvidence?) -> String? {
    guard let activeConfigurationKey, let evidence else { return nil }
    func formatKey(_ format: CaptureFormat) -> String {
      "\(format.width)x\(format.height)#\(format.fourCC)#\(format.bitsPerChannel ?? 0)#\(format.chromaSampling?.rawValue ?? "unknown")#\(format.yuvRange?.rawValue ?? "unknown")#\(format.chromaLocation?.rawValue ?? "unknown")#\(format.hasAlpha)"
    }
    return
      "\(activeConfigurationKey)#\(formatKey(evidence.selectedFormat))#\(formatKey(evidence.deliveredFormat))#\(evidence.fidelity)"
  }

  private var activeEligibilityScopeKey: String? {
    eligibilityScopeKey(for: currentEvidence)
  }

  var captureStateText: String {
    switch captureEligibility {
    case .eligible:
      return "Ready to take a photo"
    case .waitingForReadiness(let state):
      return Self.readinessDescription(state)
    case .staleFrame:
      return "Waiting for a fresh camera frame"
    case .rejectedFormat:
      return "Selected mode and delivered frame do not match"
    }
  }

  func allowCaptureWhileAdjusting() {
    guard case .stillAdjusting = readinessState else { return }
    eligibilityState.allowWhileAdjusting(readinessState)
    updateCaptureEligibility()
  }

  private func updateCaptureEligibility() {
    let scope = activeEligibilityScopeKey
    eligibilityState.selectConfiguration(scope)
    captureEligibility = eligibilityState.decision(
      configurationKey: scope,
      isFresh: latestFrameIsFresh, readiness: readinessState,
      formatIsValid: latestFormatIsValid)
    shutterEnabled = captureEligibility == .eligible
  }

  /// Public shutter entry point for the UI. Applies the optional countdown;
  /// countdown completion is the shutter event.
  func requestCapture() {
    guard captureEligibility == .eligible else { return }
    cancelCountdown()
    let countdown = max(0, Int(UserDefaults.standard.double(forKey: "countdownSeconds")))
    let revision = configurationRevision
    countdownTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if countdown > 0 {
        for remaining in stride(from: countdown, through: 1, by: -1) {
          guard !Task.isCancelled, revision == configurationRevision else { return }
          countdownRemaining = remaining
          do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
      }
      guard !Task.isCancelled, revision == configurationRevision else { return }
      countdownRemaining = nil
      await handleShutter()
      countdownTask = nil
    }
  }

  func cancelCountdown() {
    countdownTask?.cancel()
    countdownTask = nil
    countdownRemaining = nil
  }

  func handleShutter() async {
    guard captureEligibility == .eligible else {
      lastResultText = captureStateText
      return
    }
    let shutterRevision = configurationRevision
    guard let activeDeviceID, let activeGeneration, let activeMode else {
      lastResultText = "Waiting for an active camera mode"
      return
    }
    // At the shutter event, select the newest complete, sufficiently fresh
    // frame already available; if stale, wait for a fresh frame within a
    // bounded timeout.
    guard let frame = await ingest.newestFreshFrame(timeoutNanos: 250_000_000) else {
      lastResultText = "No fresh frame available"
      return
    }
    guard shutterRevision == configurationRevision else {
      lastResultText = "Capture cancelled because camera mode changed"
      return
    }
    guard frame.deviceUniqueID == activeDeviceID, frame.generation == activeGeneration else {
      lastResultText = "Capture rejected: frame belongs to a previous camera configuration"
      return
    }
    let shutterEvidence: AcquisitionEvidence
    do {
      try FrameExtraction.validateProgressiveFrame(
        sampleBuffer: frame.sampleBuffer, sourceSampleBuffer: frame.sourceSampleBuffer)
      shutterEvidence = try evaluate(
        frame: frame, selected: activeMode,
        deviceID: activeDeviceID, generation: activeGeneration)
    } catch {
      latestFormatIsValid = false
      updateCaptureEligibility()
      lastResultText = "Capture rejected: \(error.localizedDescription)"
      return
    }
    let shutterScope = eligibilityScopeKey(for: shutterEvidence)
    eligibilityState.selectConfiguration(shutterScope)
    let decision = eligibilityState.decision(
      configurationKey: shutterScope, isFresh: true, readiness: readinessState,
      formatIsValid: true)
    guard decision == .eligible else {
      lastResultText = "Capture refused: \(decision)"
      return
    }
    var snapshot = await ingest.snapshotMetadata(for: frame)
    if includeLocationPreference {
      // Use only a cached observation at the shutter. Core Location updates
      // run independently; capture is never held for a fresh fix.
      let locationCaptureTime = Date()
      let observedLocation = locationProvider.snapshotLocation(atCapture: locationCaptureTime)
      snapshot.hostLocation = LocationAcceptance.accept(
        observedLocation,
        atCaptureISO: frame.hostWallClockISO,
        policy: LocationAcceptance(maximumAgeSeconds: locationMaximumAgePreference))
    } else {
      snapshot.hostLocation = nil
    }
    if let device = cameras.first(where: { $0.uniqueID == activeDeviceID }) {
      // Host-observed device identity, recorded at the shutter for the frame
      // that was accepted (labeled as host-observed in provenance and XMP;
      // never presented as camera-Exif).
      snapshot.hostObservedDeviceMake = device.manufacturer
      snapshot.hostObservedDeviceModel = device.localizedName
      snapshot.hostObservedDeviceModelID = device.modelID
      snapshot.usbIdentity = device.usbIdentity
      snapshot.deviceIdentity = DeviceIdentityResolution.resolve(
        manufacturer: device.manufacturer, model: device.localizedName, usb: device.usbIdentity)
    }
    snapshot.captureBackend =
      switch activeBackend {
      case .cmio: "CoreMediaIO"
      case .avfoundation: "AVFoundation"
      case nil: "unknown"
      }
    snapshot.captureBackendVersion = ProcessInfo.processInfo.operatingSystemVersionString
    guard shutterRevision == configurationRevision, frame.deviceUniqueID == self.activeDeviceID,
      frame.generation == self.activeGeneration
    else {
      lastResultText = "Capture cancelled because camera mode changed during shutter processing"
      return
    }
    let capture: CapturedCapture
    do {
      capture = try CapturedCapture(
        from: frame, metadata: snapshot, acquisitionEvidence: shutterEvidence)
    } catch {
      // Honest rejection: report the exact delivered representation so the
      // inspector/user sees what was unsupported.
      let fourCC = CaptureFormat.fourCCString(frame.fourCC)
      lastResultText = "Capture rejected: unsupported representation (\(fourCC))"
      return
    }
    let saveQueueHolder = SaveQueueHolder.shared
    saveQueueHolder.trackCaptureEnqueue(capture.uuid)
    do {
      try await saveQueueHolder.queue.enqueue(capture)
      // The main window's saving indicator reports this queued capture. Keep
      // the footer's single status line from growing when a save begins.
      lastResultText = nil
    } catch {
      saveQueueHolder.captureEnqueueFailed(capture.uuid)
      lastResultText = "Capture refused: \(error.localizedDescription)"
    }
  }

  // Called from FrameIngest on a coalesced basis; hops to main actor.
  func frameArrived(
    frame: DeliveredFrame, freshnessText: String, readiness: ReadinessState,
    fresh: Bool, formatError: String?
  ) {
    guard frame.deviceUniqueID == activeDeviceID, frame.generation == activeGeneration,
      let selected = activeMode
    else { return }
    cameraWindowStatus = .ready
    readinessState = readiness
    latestFrameIsFresh = fresh
    if let formatError {
      currentEvidence = nil
      latestFormatIsValid = false
      acquisitionStatus = "Selected/delivered mismatch: \(formatError)"
    } else {
      do {
        let evidence = try evaluate(
          frame: frame, selected: selected,
          deviceID: activeDeviceID ?? "", generation: activeGeneration ?? -1)
        currentEvidence = evidence
        latestFormatIsValid = true
        let delivered = evidence.deliveredFormat
        acquisitionStatus =
          "Preserves \(delivered.width)×\(delivered.height) frames delivered by macOS"
      } catch {
        currentEvidence = nil
        latestFormatIsValid = false
        acquisitionStatus = "Selected/delivered mismatch: \(error)"
      }
    }
    // Publish only on actual change: identical assignments still invalidate
    // the whole window body.
    if readinessText != freshnessText {
      readinessText = freshnessText
    }
    updateCaptureEligibility()
  }

  func frameDecodeFailed(frame: DeliveredFrame, message: String) {
    guard frame.deviceUniqueID == activeDeviceID, frame.generation == activeGeneration else {
      return
    }
    latestFrameIsFresh = false
    latestFormatIsValid = false
    currentEvidence = nil
    cameraWindowStatus = .failed(message)
    readinessText = "H.264 decoding failed"
    acquisitionStatus = "Cannot preserve this H.264 frame: \(message)"
    updateCaptureEligibility()
  }

  func frameFormatRejected(frame: DeliveredFrame, message: String) {
    guard frame.deviceUniqueID == activeDeviceID, frame.generation == activeGeneration else {
      return
    }
    latestFrameIsFresh = false
    latestFormatIsValid = false
    currentEvidence = nil
    readinessText = "Frame rejected: \(message)"
    acquisitionStatus = "Cannot preserve this frame: \(message)"
    updateCaptureEligibility()
  }

  nonisolated static func fidelityLabel(_ f: AcquisitionFidelity) -> String {
    switch f {
    case .nativePreserved: return "native preserved (evidence-supported)"
    case .macDeliveredConverted: return "macOS-delivered (known conversion)"
    case .macDeliveredUnknownUpstream: return "macOS-delivered (upstream unknown)"
    }
  }

  private func evaluate(
    frame: DeliveredFrame, selected: CaptureFormat,
    deviceID: String, generation: Int
  ) throws -> AcquisitionEvidence {
    var fourCC = frame.fourCC
    var width = frame.width
    var height = frame.height
    if let pixel = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
      fourCC = CVPixelBufferGetPixelFormatType(pixel)
      width = CVPixelBufferGetWidth(pixel)
      height = CVPixelBufferGetHeight(pixel)
    }
    let delivered = CaptureFormat(width: width, height: height, fourCC: fourCC)
    return try AcquisitionPolicy.evaluate(
      deviceUniqueID: frame.deviceUniqueID,
      generation: frame.generation, expectedDeviceID: deviceID,
      expectedGeneration: generation, selected: selected, delivered: delivered)
  }

  nonisolated static func readinessDescription(_ state: ReadinessState) -> String {
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
