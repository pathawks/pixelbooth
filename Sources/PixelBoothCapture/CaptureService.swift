// CaptureService — AVFoundation capture service.
// Streaming configuration and blocking session operations stay off the main
// actor. Frames carry a configuration generation tag; queued frames from an
// old configuration cannot become photographs in a new mode.

import AVFoundation
import CoreMedia
import Foundation
import PixelBoothCore

/// A delivered sample with the provenance we can honestly attach.
public struct DeliveredFrame: @unchecked Sendable {
  /// Retained sample buffer; later buffer reuse cannot mutate an accepted
  /// photograph because we never write into the buffer and it is retained
  /// for the frame's lifetime.
  public var sampleBuffer: CMSampleBuffer
  public var generation: Int
  public var deviceUniqueID: String
  /// Codec FourCC at the capture boundary. For an H.264 frame decoded by
  /// VideoToolbox, `fourCC` describes the reconstructed pixel buffer while
  /// this field keeps the compressed source identity for provenance.
  public var sourceFourCC: UInt32
  /// Original compressed sample for metadata/provenance when `sampleBuffer`
  /// contains the VideoToolbox reconstructed image.
  public var sourceSampleBuffer: CMSampleBuffer?
  public var fourCC: UInt32
  public var width: Int
  public var height: Int
  public var timestampNanos: UInt64
  /// Host monotonic clock reading (`DispatchTime.uptimeNanoseconds`) taken on
  /// the capture queue at the same observation point as `hostWallClockISO`.
  /// Freshness age is measured against this reading, never against the media
  /// timestamp, whose clock domain is not the host's.
  public var hostMonotonicNanos: UInt64
  public var hostWallClockISO: String
  /// Set by bounded H.264 admission when a dependency gap requires VideoToolbox
  /// to reset before decoding the next random-access sample.
  public var requiresDecoderReset: Bool
  /// Earlier actual delivery observations; not inherited per-frame color tags.
  public var streamColorObservations: [DeliveredColorObservation]?

  public init(
    sampleBuffer: CMSampleBuffer, generation: Int, deviceUniqueID: String,
    fourCC: UInt32, width: Int, height: Int, timestampNanos: UInt64,
    hostMonotonicNanos: UInt64, hostWallClockISO: String,
    sourceFourCC: UInt32? = nil, sourceSampleBuffer: CMSampleBuffer? = nil,
    requiresDecoderReset: Bool = false,
    streamColorObservations: [DeliveredColorObservation]? = nil
  ) {
    self.sampleBuffer = sampleBuffer
    self.generation = generation
    self.deviceUniqueID = deviceUniqueID
    self.sourceFourCC = sourceFourCC ?? fourCC
    self.sourceSampleBuffer = sourceSampleBuffer
    self.fourCC = fourCC
    self.width = width
    self.height = height
    self.timestampNanos = timestampNanos
    self.hostMonotonicNanos = hostMonotonicNanos
    self.hostWallClockISO = hostWallClockISO
    self.requiresDecoderReset = requiresDecoderReset
    self.streamColorObservations = streamColorObservations
  }

  public var retainedByteCount: Int {
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      return CVPixelBufferGetDataSize(pixelBuffer)
    }
    let sampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
    if sampleSize > 0 { return sampleSize }
    if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
      let blockLength = CMBlockBufferGetDataLength(block)
      if blockLength > 0 { return blockLength }
    }
    let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
    let (estimatedSize, sizeOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
    return pixelOverflow || sizeOverflow ? Int.max : max(estimatedSize, 1)
  }

  public var isRandomAccessFrame: Bool {
    guard sourceFourCC == PixelFormatFourCC.avc1 || fourCC == PixelFormatFourCC.avc1,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
      let first = attachments.first
    else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  public var previewRoute: PreviewFrameRoute {
    if CMSampleBufferGetImageBuffer(sampleBuffer) != nil { return .pixelBuffer }
    if sourceFourCC == PixelFormatFourCC.avc1 || fourCC == PixelFormatFourCC.avc1 {
      return .decodeH264
    }
    if CaptureFormat(width: width, height: height, fourCC: sourceFourCC).codecFamily == .nativeJPEG
    {
      return .decodeJPEG
    }
    return .unavailable
  }

  /// Build the frame snapshot from a delivered sample buffer. Shared by the
  /// AVFoundation and CMIO backends so both tag frames identically: media
  /// presentation time, and host monotonic + wall-clock observations taken at
  /// the same instant on the calling (capture) queue.
  static func make(
    sampleBuffer: CMSampleBuffer, deviceUniqueID: String,
    generation: Int
  ) -> DeliveredFrame? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let fourCC = CMFormatDescriptionGetMediaSubType(formatDesc)
    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let nanos: UInt64
    if pts.isNumeric {
      let seconds = CMTimeGetSeconds(pts)
      nanos = seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    } else {
      nanos = 0
    }
    // Host observation of this delivery: monotonic (authoritative for
    // freshness age) and wall clock (provenance/anchor), taken together on
    // the capture queue so they are correlated with each other.
    let monotonicNanos = DispatchTime.now().uptimeNanoseconds
    let stamp: String = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      f.timeZone = .current
      return f.string(from: Date())
    }()
    return DeliveredFrame(
      sampleBuffer: sampleBuffer,
      generation: generation,
      deviceUniqueID: deviceUniqueID,
      fourCC: fourCC,
      width: Int(dims.width),
      height: Int(dims.height),
      timestampNanos: nanos,
      hostMonotonicNanos: monotonicNanos,
      hostWallClockISO: stamp)
  }
}

public enum PreviewFrameRoute: Sendable, Equatable {
  case pixelBuffer
  case decodeJPEG
  case decodeH264
  case unavailable
}

/// Why sample delivery stopped.
public enum StreamStopReason: Sendable, Equatable {
  /// The owner stopped the stream (window close, mode change, explicit stop).
  case stopped
  /// The capture device this stream was configured for disconnected.
  case deviceDisconnected
  /// AVFoundation reported a session runtime error.
  case runtimeError(String)
}

/// A stream ending: why, and which configured stream it was. Sinks use the
/// identity to avoid invalidating a replacement stream that started after the
/// stop was reported.
public struct StreamStop: Sendable, Equatable {
  public var reason: StreamStopReason
  public var deviceUniqueID: String?
  public var generation: Int?

  public init(reason: StreamStopReason, deviceUniqueID: String?, generation: Int?) {
    self.reason = reason
    self.deviceUniqueID = deviceUniqueID
    self.generation = generation
  }
}

/// Receives frames on a background queue, and stop notifications when the
/// stream that delivered them ends. Sinks are called from dispatch queues, so
/// conforming types must be safe to reference from other threads.
public protocol FrameSink: AnyObject, Sendable {
  func receive(_ frame: DeliveredFrame)
  /// Delivery stopped, the device disconnected, or a runtime error ended the
  /// stream. Sinks must invalidate retained frames: a frame from the stopped
  /// stream must never satisfy a later shutter. Delivery may resume with a new
  /// generation after explicit reconfiguration.
  func streamStopped(_ stop: StreamStop)
}

extension FrameSink {
  /// Default no-op for sinks that do not retain frames.
  public func streamStopped(_ stop: StreamStop) {}
}

/// Per-capture-queue delegate. Its color-observation tracker is accessed only
/// by callbacks on the single serial capture queue. A new delegate is created
/// for each configured stream; immutable device/generation context never changes.
final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  weak var service: CaptureService?
  let deviceUniqueID: String
  let generation: Int
  private var colorTracker = StreamColorObservationTracker()

  init(service: CaptureService, deviceUniqueID: String, generation: Int) {
    self.service = service
    self.deviceUniqueID = deviceUniqueID
    self.generation = generation
    super.init()
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let service,
      var frame = DeliveredFrame.make(
        sampleBuffer: sampleBuffer, deviceUniqueID: deviceUniqueID, generation: generation)
    else { return }
    frame.streamColorObservations = colorTracker.observe(frame)
    service.forwardFrame(frame)
  }
}

/// Sink registry that the capture queue can read without awaiting the actor.
/// Written on the actor; read from the capture queue. Documented narrow
/// exception: the lock protects a plain dictionary used only for forwarding.
final class SinkRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [ObjectIdentifier: BoundedFrameSinkDelivery] = [:]

  func set(_ sink: FrameSink, queue: DispatchQueue) {
    lock.lock()
    defer { lock.unlock() }
    entries[ObjectIdentifier(sink)] = BoundedFrameSinkDelivery(sink: sink, queue: queue)
  }

  func remove(_ sink: FrameSink) {
    lock.lock()
    defer { lock.unlock() }
    entries.removeValue(forKey: ObjectIdentifier(sink))?.reset()
  }

  func snapshot() -> [BoundedFrameSinkDelivery] {
    lock.lock()
    defer { lock.unlock() }
    return Array(entries.values)
  }
}

/// A per-sink dispatch boundary with fixed retained-frame limits. It schedules
/// at most one drain task per independent-image slot or H.264 dependency queue.
final class BoundedFrameSinkDelivery: @unchecked Sendable {
  private static let maximumIndependentBytes = 128 * 1024 * 1024
  private static let maximumH264Frames = 16
  private static let maximumH264Bytes = 64 * 1024 * 1024

  private let sink: FrameSink
  private let queue: DispatchQueue
  private let independentFrames = FrameAdmissionMailbox<DeliveredFrame>(
    policy: .latest(maximumBytes: maximumIndependentBytes))
  private let dependentFrames = FrameAdmissionMailbox<DeliveredFrame>(
    policy: .dependencyPreserving(
      maximumFrames: maximumH264Frames, maximumBytes: maximumH264Bytes))

  init(sink: FrameSink, queue: DispatchQueue) {
    self.sink = sink
    self.queue = queue
  }

  func offer(_ frame: DeliveredFrame) {
    if frame.sourceFourCC == PixelFormatFourCC.avc1 {
      let result = dependentFrames.offer(
        frame, byteCount: frame.retainedByteCount,
        isRandomAccessFrame: frame.isRandomAccessFrame)
      if result.shouldScheduleDrain { queue.async { [self] in drain(dependentFrames) } }
    } else {
      let result = independentFrames.offer(frame, byteCount: frame.retainedByteCount)
      if result.shouldScheduleDrain { queue.async { [self] in drain(independentFrames) } }
    }
  }

  func streamStopped(_ stop: StreamStop) {
    reset()
    queue.async { [sink] in sink.streamStopped(stop) }
  }

  func reset() {
    independentFrames.reset()
    dependentFrames.reset()
  }

  private func drain(_ mailbox: FrameAdmissionMailbox<DeliveredFrame>) {
    while let delivery = mailbox.takeNext() {
      var frame = delivery.value
      frame.requiresDecoderReset = delivery.requiresDecoderReset
      sink.receive(frame)
    }
  }
}

/// The capture service. Owns the AVCaptureSession and its configuration.
public actor CaptureService {
  private var session: AVCaptureSession?
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private var currentDevice: AVCaptureDevice?
  private var currentInput: AVCaptureDeviceInput?
  private var generation: Int = 0
  private let sinkRegistry = SinkRegistry()
  private var delegate: CaptureDelegate?
  private var captureQueue: DispatchQueue?
  private var stopObservers: [NSObjectProtocol] = []
  private var isStreaming = false
  public private(set) var configuredFrameRate: Double?

  public init() {}

  /// Configure the (long-lived) capture session for the device with the
  /// given unique ID and mode. The session is created once and reconfigured
  /// in place so the preview layer's attachment survives mode changes.
  /// videoSettings: an explicitly EMPTY (non-nil) dictionary, requesting
  /// native-format delivery per TN3121 — verified against the installed SDK
  /// (see docs/TN3121_VERIFICATION.md; the SDK normalizes the empty
  /// dictionary to nil, so delivered buffers are the classification
  /// evidence, never the configuration alone).
  public func configure(
    deviceUniqueID: String, mode: CameraMode,
    requestedFrameRate: Double? = nil, generation requestedGeneration: Int? = nil,
    operationToken: CaptureConfigurationToken? = nil
  ) throws -> Int {
    if let requestedGeneration, let operationToken,
      !operationToken.isCurrent(requestedGeneration)
    {
      throw CaptureServiceError.configurationSuperseded
    }
    guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
      throw CaptureServiceError.cannotAddInput
    }
    // Detach and drain any callbacks before replacing their immutable mode
    // context. Old queued buffers retain the prior generation and are rejected.
    detachDelivery()
    generation = requestedGeneration ?? (generation + 1)

    // One long-lived session: recreate-per-mode-change broke the preview
    // (black) because start() refused to run the new session.
    let target = session ?? AVCaptureSession()
    if session == nil { session = target }

    target.stopRunning()
    target.beginConfiguration()
    // Note: .inputPriority preset is unavailable on macOS; the device's
    // activeFormat (set below) governs geometry.
    if let oldInput = currentInput, target.inputs.contains(oldInput) {
      target.removeInput(oldInput)
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard target.canAddInput(input) else {
      target.commitConfiguration()
      throw CaptureServiceError.cannotAddInput
    }
    target.addInput(input)

    // Create the video data output once; keep it (and its delegate) across
    // mode changes. An explicitly EMPTY dictionary requests native-format
    // delivery (TN3121; normalized to nil by the installed SDK — documented).
    if videoDataOutput == nil {
      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [:]
      output.alwaysDiscardsLateVideoFrames = false
      guard target.canAddOutput(output) else {
        target.commitConfiguration()
        throw CaptureServiceError.cannotAddOutput
      }
      target.addOutput(output)
      videoDataOutput = output
    }
    target.commitConfiguration()

    currentDevice = device
    currentInput = input

    // Setting activeFormat requires the device not to be actively running
    // in a session; stop first, configure, then restart below.
    // Verified on macOS 27.0 Build 26A428 (docs/TN3121_VERIFICATION.md,
    // finding 3): on this OS build the session ignores both session presets
    // and activeFormat for built-in cameras and delivers only the camera's
    // default stream. The format below is still requested — and on other
    // cameras/OS versions it may govern — but delivered sample buffers,
    // not this configuration, are the acquisition-fidelity evidence.
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      // Lock the negotiated format to the selected mode.
      let matchingFormat: AVCaptureDevice.Format? = {
        if let formatID = mode.formatID, let index = Int(formatID),
          device.formats.indices.contains(index)
        {
          return device.formats[index]
        }
        if let formatID = mode.formatID, formatID.hasPrefix("cmio-") {
          return device.formats.first(where: { format in
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            return CMIOCaptureDiscovery.formatIdentity(description) == formatID
              && Int(dimensions.width) == mode.dimensions.width
              && Int(dimensions.height) == mode.dimensions.height
              && CMFormatDescriptionGetMediaSubType(description) == mode.mediaSubType
          })
        }
        guard mode.formatID == nil else { return nil }
        return device.formats.first(where: { fmt in
          let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
          return Int(d.width) == mode.dimensions.width && Int(d.height) == mode.dimensions.height
            && CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == mode.mediaSubType
        })
      }()
      guard let matchedFormat = matchingFormat else { throw CaptureServiceError.modeUnavailable }
      let matchedDimensions = CMVideoFormatDescriptionGetDimensions(matchedFormat.formatDescription)
      guard Int(matchedDimensions.width) == mode.dimensions.width,
        Int(matchedDimensions.height) == mode.dimensions.height,
        CMFormatDescriptionGetMediaSubType(matchedFormat.formatDescription) == mode.mediaSubType
      else {
        throw CaptureServiceError.modeUnavailable
      }
      if let requestedGeneration, let operationToken,
        !operationToken.isCurrent(requestedGeneration)
      {
        throw CaptureServiceError.configurationSuperseded
      }
      device.activeFormat = matchedFormat
      let supportedRanges = matchedFormat.videoSupportedFrameRateRanges.map {
        SupportedFrameRateRange(
          minimum: 1.0 / $0.maxFrameDuration.seconds,
          maximum: 1.0 / $0.minFrameDuration.seconds)
      }
      let ceiling = requestedFrameRate ?? (mode.maxFrameRate > 0 ? mode.maxFrameRate : nil)
      configuredFrameRate = FrameRateSelection.highestSupported(
        in: supportedRanges, ceiling: ceiling)
      if configuredFrameRate == nil, ceiling != nil {
        throw CaptureServiceError.frameRateUnavailable
      }
      if let rate = configuredFrameRate {
        let duration = CMTime(seconds: 1.0 / rate, preferredTimescale: 60_000)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
      }
    }
    // Restart delivery in the final selected mode (warm-up in final mode;
    // no restart at the shutter).
    return generation
  }

  /// Attach an advanced lower-frame-rate override (explicit user request).
  public func setFrameRateOverride(_ fps: Double) throws {
    guard let device = currentDevice, fps > 0 else { return }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    let duration = CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
    configuredFrameRate = fps
  }

  /// Ensure continuous delivery. Idempotent; the delegate is attached once
  /// per output lifetime.
  public func start(
    expectedGeneration: Int? = nil, operationToken: CaptureConfigurationToken? = nil
  ) throws {
    if let expectedGeneration, expectedGeneration != generation {
      throw CaptureServiceError.configurationSuperseded
    }
    if let expectedGeneration, let operationToken,
      !operationToken.isCurrent(expectedGeneration)
    {
      throw CaptureServiceError.configurationSuperseded
    }
    guard let session, let output = videoDataOutput, let device = currentDevice else {
      throw CaptureServiceError.notConfigured
    }
    if delegate == nil {
      PreviewSessionHolder.shared.install(session)
      let queue = DispatchQueue(label: "app.pixelbooth.capture.video", qos: .userInteractive)
      captureQueue = queue
      let delegate = CaptureDelegate(
        service: self, deviceUniqueID: device.uniqueID, generation: generation)
      output.setSampleBufferDelegate(delegate, queue: queue)
      self.delegate = delegate
    }
    if !session.isRunning {
      session.startRunning()
    }
    isStreaming = session.isRunning
    installStopObservers()
  }

  /// Stop camera use (also on window close). Sinks are told delivery stopped
  /// so they can invalidate retained frames instead of treating the last frame
  /// as current.
  public func stop(expectedGeneration: Int? = nil) {
    guard let session else { return }
    if let expectedGeneration, expectedGeneration != generation { return }
    let deviceID = currentDevice?.uniqueID
    let observedGeneration = generation
    detachDelivery()
    session.stopRunning()
    PreviewSessionHolder.shared.clear(ifMatching: session)
    notifyStreamStopped(
      reason: .stopped,
      deviceID: deviceID, observedGeneration: observedGeneration)
  }

  /// Detach the sample-buffer delegate and drain the capture queue so no
  /// further frames enter the sink pipeline. Does not notify sinks; callers
  /// that end a user-visible stream must do so explicitly.
  private func detachDelivery() {
    if let output = videoDataOutput {
      output.setSampleBufferDelegate(nil, queue: nil)
      if let captureQueue { captureQueue.sync {} }
    }
    delegate = nil
    isStreaming = false
    removeStopObservers()
    if let session { PreviewSessionHolder.shared.clear(ifMatching: session) }
  }

  /// A device disconnect or session runtime error ends delivery outside any
  /// app-initiated stop. The identity captured when the observers were
  /// installed must still be current, so an event for a stream that has since
  /// been replaced cannot tear down the replacement. Report honestly; never
  /// auto-activate another camera.
  private func handleExternalStreamStop(
    _ reason: StreamStopReason, deviceID: String, observedGeneration: Int
  ) {
    guard deviceID == currentDevice?.uniqueID, observedGeneration == generation else { return }
    guard isStreaming || delegate != nil || session?.isRunning == true else { return }
    detachDelivery()
    session?.stopRunning()
    notifyStreamStopped(
      reason: reason,
      deviceID: deviceID, observedGeneration: observedGeneration)
  }

  private func notifyStreamStopped(
    reason: StreamStopReason, deviceID: String?, observedGeneration: Int?
  ) {
    let stop = StreamStop(
      reason: reason,
      deviceUniqueID: deviceID,
      generation: observedGeneration)
    for entry in sinkRegistry.snapshot() { entry.streamStopped(stop) }
  }

  private func installStopObservers() {
    removeStopObservers()
    guard let session, let device = currentDevice else { return }
    let deviceID = device.uniqueID
    let observedGeneration = generation
    let center = NotificationCenter.default
    stopObservers.append(
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification,
        object: device,
        queue: nil
      ) { [weak self] _ in
        Task {
          await self?.handleExternalStreamStop(
            .deviceDisconnected, deviceID: deviceID, observedGeneration: observedGeneration)
        }
      })
    stopObservers.append(
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification,
        object: session,
        queue: nil
      ) { [weak self] note in
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let message = error?.localizedDescription ?? "unknown runtime error"
        Task {
          await self?.handleExternalStreamStop(
            .runtimeError(message), deviceID: deviceID, observedGeneration: observedGeneration)
        }
      })
  }

  private func removeStopObservers() {
    let observers = stopObservers
    stopObservers.removeAll()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  public func addSink(_ sink: FrameSink, queue: DispatchQueue) {
    sinkRegistry.set(sink, queue: queue)
  }

  public func removeSink(_ sink: FrameSink) {
    sinkRegistry.remove(sink)
  }

  /// Read-only session handle for the preview layer (display only).
  /// Nonisolated + cheap (lock + return) so the preview can re-attach on
  /// every SwiftUI update without spawning tasks or hopping actors.
  public nonisolated static func previewSession() -> AVCaptureSession? {
    PreviewSessionHolder.shared.current()
  }

  /// Called from the capture queue's delegate. Nonisolated so it can run
  /// directly on the capture queue without hopping to the actor executor.
  public nonisolated func forwardBuffer(
    _ buffer: CMSampleBuffer, deviceUniqueID: String, generation: Int
  ) {
    guard
      let frame = DeliveredFrame.make(
        sampleBuffer: buffer, deviceUniqueID: deviceUniqueID, generation: generation)
    else { return }
    forwardFrame(frame)
  }

  nonisolated func forwardFrame(_ frame: DeliveredFrame) {
    for entry in sinkRegistry.snapshot() { entry.offer(frame) }
  }

}

public enum CaptureServiceError: Error {
  case cannotAddInput
  case cannotAddOutput
  case notConfigured
  case modeUnavailable
  case frameRateUnavailable
  case configurationSuperseded
}

/// Thread-safe accessors bridging the actor's state to the capture queue.
/// The boxes are written on the actor and read from the capture queue via
/// locks; they hold only immutable snapshots.
/// Process-wide session holder for preview attachment. Written on the actor
/// when a session starts; read by the preview view. Documented narrow
/// exception: an AVCaptureSession must be referenced directly by CALayer.
public final class PreviewSessionHolder: @unchecked Sendable {
  public static let shared = PreviewSessionHolder()
  private let lock = NSLock()
  private var session: AVCaptureSession?

  public init() {}

  public func install(_ session: AVCaptureSession) {
    lock.lock()
    self.session = session
    lock.unlock()
  }

  public func current() -> AVCaptureSession? {
    lock.lock()
    defer { lock.unlock() }
    return session
  }

  public func clear(ifMatching session: AVCaptureSession) {
    lock.lock()
    if self.session === session { self.session = nil }
    lock.unlock()
  }
}
