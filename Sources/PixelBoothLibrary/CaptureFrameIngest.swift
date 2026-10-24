// Shared bounded frame ingestion, H.264 decode and readiness processing.
// Presentation observes events; archival processing never depends on preview.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothMetadata
import os

public enum CaptureFrameIngestEvent: Sendable {
  case frame(frame: DeliveredFrame, readiness: ReadinessState, fresh: Bool, formatError: String?)
  case decodedFrame(DeliveredFrame)
  case decodeFailure(frame: DeliveredFrame, message: String)
  case fieldMetadataFailure(frame: DeliveredFrame, message: String)
  case stopped(StreamStop)
}

/// Receives frames on the capture queue (not main-actor isolated).
public final class CaptureFrameIngest: FrameSink, @unchecked Sendable {
  // @unchecked Sendable is limited to queue-confined decoder state and the
  // lock-protected observer/configuration state. Frame ownership lives in the
  // FrameStore actor; mailboxes bound pending work before dispatch.
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
    var handler: (@Sendable (CaptureFrameIngestEvent) async -> Void)?
    var stoppedStream: StreamStop?
  }

  public init() {}

  public func setEventHandler(
    _ handler: @escaping @Sendable (CaptureFrameIngestEvent) async -> Void
  ) {
    coalescer.withLock { $0.handler = handler }
  }

  public var lastFailureMessage: String? {
    coalescer.withLock { $0.lastFormatError }
  }

  public var stoppedStream: StreamStop? {
    coalescer.withLock { $0.stoppedStream }
  }

  public func currentReadiness() async -> ReadinessState {
    await store.currentReadiness()
  }

  private func emit(_ event: CaptureFrameIngestEvent) async {
    let handler = coalescer.withLock { $0.handler }
    await handler?(event)
  }

  public func receive(_ frame: DeliveredFrame) {
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
      sourceSampleBuffer: source.sourceSampleBuffer ?? source.sampleBuffer,
      streamColorObservations: source.streamColorObservations)
    return decodedFrame
  }

  private func publishDecodeError(_ frame: DeliveredFrame, _ message: String) {
    let shouldPublish = coalescer.withLock { state in
      guard state.generation == frame.generation, state.deviceID == frame.deviceUniqueID,
        state.lastFormatError != message
      else { return false }
      state.lastFormatError = message
      state.lastFresh = false
      state.lastPublishNanos = DispatchTime.now().uptimeNanoseconds
      return true
    }
    guard shouldPublish else { return }
    Task { await emit(.decodeFailure(frame: frame, message: message)) }
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
    // Coalesce presentation events without coupling archival ingestion to UI.
    let shouldPublish = coalescer.withLock { state in
      guard state.generation == frame.generation else { return false }
      let changed =
        state.lastState != readiness || state.lastFresh != isFresh
        || state.lastFormatError != formatError
      let now = DispatchTime.now().uptimeNanoseconds
      let due = now &- state.lastPublishNanos > 250_000_000
      guard changed || due else { return false }
      state.lastState = readiness
      state.lastFresh = isFresh
      state.lastFormatError = formatError
      state.lastPublishNanos = now
      return true
    }
    if frame.sourceFourCC == PixelFormatFourCC.avc1 {
      await emit(.decodedFrame(frame))
    }
    guard shouldPublish else { return }
    await emit(.frame(frame: frame, readiness: readiness, fresh: isFresh, formatError: formatError))
  }

  private func publishFieldMetadataFailure(_ frame: DeliveredFrame, message: String) {
    let shouldPublish = coalescer.withLock { state in
      guard state.generation == frame.generation, state.deviceID == frame.deviceUniqueID else {
        return false
      }
      state.lastFormatError = message
      state.lastFresh = false
      state.lastPublishNanos = DispatchTime.now().uptimeNanoseconds
      return true
    }
    guard shouldPublish else { return }
    Task { await emit(.fieldMetadataFailure(frame: frame, message: message)) }
  }

  public func newestFreshFrame(timeoutNanos: UInt64) async -> DeliveredFrame? {
    await store.newestFreshFrame(timeoutNanos: timeoutNanos)
  }

  public func frameRates() async -> (requested: Double, measured: Double) {
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
      $0.stoppedStream = nil
    }
  }

  public func beginConfiguration(
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
  public func invalidateConfiguration() async {
    resetPublishing(generation: nil)
    latestFrameMailbox.reset()
    dependentFrameMailbox.reset()
    processingQueue.async { [h264Decoder] in h264Decoder.invalidate() }
    await store.invalidate()
  }

  /// Drop retained frames for the stopping stream and reset coalesced
  /// readiness publishing. A delayed stop for an already-replaced stream is
  /// ignored by the store, so the window is not told to shut down either.
  public func streamStopped(_ stop: StreamStop) {
    let ingest = self
    Task {
      guard
        await store.invalidateIfActive(
          deviceID: stop.deviceUniqueID, generation: stop.generation)
      else { return }
      // Configuration can advance while invalidation awaits the store actor.
      // Check the publishing identity again before resetting newer state.
      let stillCurrent = ingest.coalescer.withLock { state in
        if let deviceID = stop.deviceUniqueID, state.deviceID != deviceID { return false }
        if let generation = stop.generation, state.generation != generation { return false }
        state.generation = nil
        state.deviceID = nil
        state.expectedFormat = nil
        state.lastFresh = false
        state.lastState = .noStream
        state.lastFormatError = nil
        state.lastPublishNanos = 0
        state.stoppedStream = stop
        return true
      }
      guard stillCurrent else { return }
      ingest.latestFrameMailbox.reset()
      ingest.dependentFrameMailbox.reset()
      ingest.processingQueue.async { [h264Decoder = ingest.h264Decoder] in
        h264Decoder.invalidate()
      }
      await ingest.emit(.stopped(stop))
    }
  }

  public func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    await store.snapshotMetadata(for: frame)
  }

  public func setReadinessHeuristic(_ heuristic: ReadinessHeuristic) async {
    await store.setReadinessHeuristic(heuristic)
  }
}
