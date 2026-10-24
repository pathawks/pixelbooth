// FrameStore — immutable captured-frame ownership.
// The store owns retained sample buffers. Once a frame is stored, later
// buffer reuse in the capture pipeline cannot mutate an accepted photograph:
// CMSampleBuffer is retained and never written into.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothMetadata

public actor FrameStore {
  /// The stream configuration whose frames may be stored and selected.
  /// Explicit on purpose: a store with no active configuration rejects every
  /// frame, so a callback that arrives before configuration (or after
  /// invalidation/reconfiguration) can never become a photograph.
  public struct ActiveConfiguration: Sendable, Equatable {
    public var deviceUniqueID: String
    public var generation: Int
    public var frameIntervalNanos: UInt64

    public init(deviceUniqueID: String, generation: Int, frameIntervalNanos: UInt64) {
      self.deviceUniqueID = deviceUniqueID
      self.generation = generation
      self.frameIntervalNanos = frameIntervalNanos
    }
  }

  private var frames: [DeliveredFrame] = []
  private var frameIntervalNanos: UInt64 = 33_333_333  // refined from mode
  private var readinessHeuristic: ReadinessHeuristic
  private var readiness: ReadinessStateMachine

  /// Retain at most this many recent frames to bound memory.
  private var maxFrames = 12
  public private(set) var activeConfiguration: ActiveConfiguration?

  public init(heuristic: ReadinessHeuristic = .default) {
    readinessHeuristic = heuristic
    readiness = ReadinessStateMachine(heuristic: heuristic)
  }

  public func beginConfiguration(deviceID: String, generation: Int, frameIntervalNanos: UInt64) {
    invalidate()
    // Freshness window follows the selected mode's advertised interval. An
    // unknown rate keeps the conservative 30 fps default.
    let interval = frameIntervalNanos > 0 ? frameIntervalNanos : 33_333_333
    self.frameIntervalNanos = interval
    requestedFrameRate =
      frameIntervalNanos > 0
      ? 1_000_000_000.0 / Double(frameIntervalNanos) : 0
    activeConfiguration = ActiveConfiguration(
      deviceUniqueID: deviceID, generation: generation, frameIntervalNanos: interval)
  }

  /// Drop every retained frame and the active stream identity. Called when
  /// delivery stops or the device disconnects, so no frame from the stopped
  /// stream can satisfy a later shutter — including frames already queued
  /// toward the store when the stop was reported (they no longer match the
  /// active device/generation). Until the next `beginConfiguration`, every
  /// frame is rejected: there is no active configuration to belong to.
  public func invalidate() {
    activeConfiguration = nil
    frames.removeAll(keepingCapacity: true)
    measuredFrameRate = 0
    readiness = ReadinessStateMachine(heuristic: readinessHeuristic)
  }

  /// Invalidate only when the reported stop still matches the active stream.
  /// Returns true when this call invalidated that stream; false when the stop
  /// belongs to an already-replaced configuration (nothing is dropped and the
  /// replacement's frames stay valid) or when no configuration is active.
  @discardableResult
  public func invalidateIfActive(deviceID: String?, generation: Int?) -> Bool {
    if let active = activeConfiguration {
      if let deviceID, deviceID != active.deviceUniqueID { return false }
      if let generation, generation != active.generation { return false }
    } else if deviceID != nil || generation != nil {
      // A stop for a specific stream cannot invalidate anything when no
      // configuration is active (the store already holds nothing selectable).
      return false
    }
    invalidate()
    return true
  }

  /// Append a frame only when it belongs to the explicitly active
  /// configuration. Obsolete callbacks (queued before reconfiguration, or
  /// arriving after invalidation) are rejected before storage, so retained
  /// frames never mix configurations.
  @discardableResult
  public func store(_ frame: DeliveredFrame) -> Bool {
    guard let active = activeConfiguration,
      frame.deviceUniqueID == active.deviceUniqueID,
      frame.generation == active.generation
    else { return false }
    frames.append(frame)
    if frames.count > maxFrames {
      frames.removeFirst(frames.count - maxFrames)
    }
    return true
  }

  /// The newest complete frame that is sufficiently fresh at evaluation time.
  /// Waits up to `timeoutNanos` for a fresh frame if the newest is stale.
  /// Clock and polling dependencies allow deterministic tests of delivery and
  /// expiry without relying on executor scheduling within a freshness window.
  public func newestFreshFrame(
    timeoutNanos: UInt64,
    nowNanos: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    waitForNextPoll: @Sendable () async -> Void = {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  ) async -> DeliveredFrame? {
    let deadline = nowNanos() + timeoutNanos
    while true {
      let now = nowNanos()
      if let candidate = newestEligibleFrame(nowNanos: now) {
        return candidate
      }
      if now >= deadline { return nil }
      await waitForNextPoll()
    }
  }

  /// Current readiness for the shutter: does a fresh frame exist?
  public func freshFrameAvailable() -> Bool {
    newestEligibleFrame(nowNanos: DispatchTime.now().uptimeNanoseconds) != nil
  }

  /// Freshness is the host-monotonic age of the frame at `now`, so a stopped
  /// stream goes stale as time passes instead of freezing at its last frame.
  public func isFresh(_ frame: DeliveredFrame) -> Bool {
    isFresh(frame, nowNanos: DispatchTime.now().uptimeNanoseconds)
  }

  public func isFresh(_ frame: DeliveredFrame, nowNanos: UInt64) -> Bool {
    FrameFreshness.isFresh(
      frameObservedNanos: frame.hostMonotonicNanos,
      nowNanos: nowNanos,
      frameIntervalNanos: frameIntervalNanos)
  }

  /// The newest eligible frame: one that is fresh at `nowNanos` (only frames
  /// in the active configuration are retained at all). Selection is by media
  /// presentation timestamp — the camera's content clock — not callback
  /// arrival order, so a frame delivered late with an older presentation time
  /// cannot displace newer content. Streams without a numeric presentation
  /// timestamp fall back to host observation order; append order is still
  /// never a clock, because sink callbacks can reach the actor out of order.
  private func newestEligibleFrame(nowNanos: UInt64) -> DeliveredFrame? {
    frames
      .filter { isFresh($0, nowNanos: nowNanos) }
      .max { a, b in
        if a.timestampNanos != b.timestampNanos {
          return a.timestampNanos < b.timestampNanos
        }
        return a.hostMonotonicNanos < b.hostMonotonicNanos
      }
  }

  /// Whether the frame belongs to the explicitly active configuration.
  /// Comparing against retained frames (e.g. the just-appended one) is not
  /// enough: the store may have appended that frame only because it was queued
  /// before reconfiguration, so `frames.last` can itself be obsolete.
  public func isCurrentGeneration(_ frame: DeliveredFrame) -> Bool {
    isInActiveConfiguration(frame)
  }

  public func isInActiveConfiguration(_ frame: DeliveredFrame) -> Bool {
    guard let active = activeConfiguration else { return false }
    return frame.deviceUniqueID == active.deviceUniqueID
      && frame.generation == active.generation
  }

  /// Snapshot metadata applicable to the selected frame (not "current"
  /// metadata at encode time).
  public func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    var pixelAttachments: [String: String] = [:]
    var sampleAttachments: [String: String] = [:]
    let sourceSample = frame.sourceSampleBuffer ?? frame.sampleBuffer
    if let pb = frame.sampleBuffer.imageBuffer {
      let copiedAttachments =
        CMCopyDictionaryOfAttachments(
          allocator: nil, target: pb as CMAttachmentBearer,
          attachmentMode: CMAttachmentMode(1)  // kCVAttachmentMode_ShouldPropagate
        ) as? [String: String]
      pixelAttachments = copiedAttachments ?? [:]
      let extensions =
        CMSampleBufferGetFormatDescription(sourceSample)
        .flatMap { CMFormatDescriptionGetExtensions($0) } as? [CFString: Any] ?? [:]
      let stringColorKeys: [CFString] = [
        kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey, kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
      ]
      var completeColorSnapshot = true
      for key in stringColorKeys {
        let pixelValue = CVBufferCopyAttachment(pb, key, nil)
        let formatValue = extensions[key] as CFTypeRef?
        if let pixelValue, let formatValue, !CFEqual(pixelValue, formatValue) {
          completeColorSnapshot = false
          continue
        }
        guard let value = pixelValue ?? formatValue else { continue }
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
          completeColorSnapshot = false
          continue
        }
        pixelAttachments[key as String] = String(describing: value)
      }

      let nonStringColorKeys: [CFString] = [
        kCVImageBufferICCProfileKey, kCVImageBufferCGColorSpaceKey,
        kCVImageBufferContentLightLevelInfoKey, kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferLogTransferFunctionKey, kCVImageBufferGammaLevelKey,
        kCVImageBufferAmbientViewingEnvironmentKey,
      ]
      for key in nonStringColorKeys {
        if CVBufferCopyAttachment(pb, key, nil) != nil || extensions[key] != nil {
          completeColorSnapshot = false
        }
      }
      pixelAttachments[CapturedCapture.completeColorAttachmentSnapshotKey] =
        completeColorSnapshot ? "true" : "false"
    }
    if CMGetAttachment(
      sourceSample as CMAttachmentBearer,
      key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
      attachmentModeOut: nil) != nil
    {
      // NOTE: camera intrinsic matrix presence is recorded as an observation,
      // not as source pixel metadata.
      sampleAttachments["CameraIntrinsicMatrixPresent"] = "true"
    }
    return FrameMetadataSnapshot(
      sampleBufferAttachments: sampleAttachments,
      pixelBufferAttachments: pixelAttachments,
      formatDescriptionData: [:],
      embeddedSourceExif: nil,
      embeddedSourceXMP: nil,
      embeddedSourceICC: nil,
      unknownSegments: [],
      hostObservations: [],
      hostLocation: nil,
      mediaTimeNanos: frame.timestampNanos,
      wallClockAnchorISO: frame.hostWallClockISO,
      generation: frame.generation)
  }

  /// Update the frame interval when the mode changes; records the requested
  /// rate. A zero interval is ignored: a zero-width freshness window would
  /// reject every frame.
  public func setFrameIntervalNanos(_ nanos: UInt64) {
    guard nanos > 0 else { return }
    frameIntervalNanos = nanos
    requestedFrameRate = 1_000_000_000.0 / Double(nanos)
  }

  /// A user preference change restarts warm-up under the new heuristic so
  /// the shutter cannot retain a readiness result from the old threshold.
  public func setReadinessHeuristic(_ heuristic: ReadinessHeuristic) {
    readinessHeuristic = heuristic
    readiness = ReadinessStateMachine(heuristic: heuristic)
  }

  public func currentReadiness(adjusting: Bool = false) -> ReadinessState {
    readiness.currentState(
      monotonicNanos: DispatchTime.now().uptimeNanoseconds, adjusting: adjusting)
  }

  /// Record a frame into the readiness state machine and evaluate the state.
  /// Also tracks requested vs measured frame rate from timestamp deltas.
  public func recordAndEvaluate(
    generation: Int, isStale: Bool, adjusting: Bool, monotonicNanos: UInt64
  ) async -> ReadinessState {
    updateMeasuredFrameRate()
    return readiness.recordFrame(
      generation: generation, isStale: isStale, adjusting: adjusting,
      monotonicNanos: monotonicNanos)
  }

  /// Record a delivered frame for readiness only while it still belongs to the
  /// active configuration. Returns nil when reconfiguration or invalidation
  /// raced with delivery, so an obsolete callback cannot publish readiness
  /// (or reset readiness state) for a configuration it does not belong to.
  /// Staleness is the frame's host-monotonic age, not a comparison with other
  /// frames.
  public func recordAndEvaluate(frame: DeliveredFrame, adjusting: Bool) async -> ReadinessState? {
    guard isInActiveConfiguration(frame) else { return nil }
    let monotonicNanos = DispatchTime.now().uptimeNanoseconds
    let isStale = !isFresh(frame, nowNanos: monotonicNanos)
    updateMeasuredFrameRate()
    return readiness.recordFrame(
      generation: frame.generation, isStale: isStale, adjusting: adjusting,
      monotonicNanos: monotonicNanos)
  }

  /// Measured delivery rate from the two newest distinct presentation
  /// timestamps, falling back to host observation deltas when the stream
  /// carries no numeric media timestamps. Insertion order is never used.
  private func updateMeasuredFrameRate() {
    let mediaStamps = frames.map(\.timestampNanos).filter { $0 > 0 }.sorted()
    if mediaStamps.count >= 2 {
      let delta = mediaStamps[mediaStamps.count - 1] &- mediaStamps[mediaStamps.count - 2]
      if delta > 0 {
        measuredFrameRate = 1_000_000_000.0 / Double(delta)
        return
      }
    }
    let observed = frames.map(\.hostMonotonicNanos).sorted()
    if observed.count >= 2 {
      let delta = observed[observed.count - 1] &- observed[observed.count - 2]
      if delta > 0 {
        measuredFrameRate = 1_000_000_000.0 / Double(delta)
      }
    }
  }

  /// Requested frame rate (from the mode's advertised interval).
  public private(set) var requestedFrameRate: Double = 0
  /// Measured frame rate (from delivered timestamp deltas).
  public private(set) var measuredFrameRate: Double = 0
}
