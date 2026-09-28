// FrameStore — immutable captured-frame ownership.
// The store owns retained sample buffers. Once a frame is stored, later
// buffer reuse in the capture pipeline cannot mutate an accepted photograph:
// CMSampleBuffer is retained and never written into.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import PixelBoothCore
import PixelBoothCapture
import PixelBoothMetadata

public actor FrameStore {
  private var frames: [DeliveredFrame] = []
  private var newestTimestampNanos: UInt64 = 0
  private var frameIntervalNanos: UInt64 = 33_333_333  // refined from mode
  private var readiness = ReadinessStateMachine()

  /// Retain at most this many recent frames to bound memory.
  private var maxFrames = 12

  public init() {}

  public func store(_ frame: DeliveredFrame) {
    newestTimestampNanos = max(newestTimestampNanos, frame.timestampNanos)
    frames.append(frame)
    if frames.count > maxFrames {
      frames.removeFirst(frames.count - maxFrames)
    }
  }

  /// The newest complete frame that is sufficiently fresh. Waits up to
  /// `timeoutNanos` for a fresh frame if the newest is stale.
  public func newestFreshFrame(timeoutNanos: UInt64) async -> DeliveredFrame? {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
    while true {
      if let candidate = frames.last, isFresh(candidate) {
        return candidate
      }
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        return frames.last.flatMap { isFresh($0) ? $0 : nil }
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// Current readiness for the shutter: does a fresh frame exist?
  public func freshFrameAvailable() -> Bool {
    frames.last.map { isFresh($0) } ?? false
  }

  public func isFresh(_ frame: DeliveredFrame) -> Bool {
    FrameFreshness.isFresh(
      frameNanos: frame.timestampNanos,
      newestObservedNanos: newestTimestampNanos,
      frameIntervalNanos: frameIntervalNanos)
  }

  public func isCurrentGeneration(_ frame: DeliveredFrame) -> Bool {
    guard let newest = frames.last else { return false }
    return frame.generation == newest.generation
  }

  /// Snapshot metadata applicable to the selected frame (not "current"
  /// metadata at encode time).
  public func snapshotMetadata(for frame: DeliveredFrame) async -> FrameMetadataSnapshot {
    var pixelAttachments: [String: String] = [:]
    var sampleAttachments: [String: String] = [:]
    if let pb = frame.sampleBuffer.imageBuffer {
      pixelAttachments = CMCopyDictionaryOfAttachments(
        allocator: nil, target: pb as CMAttachmentBearer,
        attachmentMode: CMAttachmentMode(1) // kCVAttachmentMode_ShouldPropagate
      ) as? [String: String] ?? [:]
    }
    if CMGetAttachment(
      frame.sampleBuffer as CMAttachmentBearer,
      key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
      attachmentModeOut: nil) != nil {
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

  /// Update the frame interval when the mode changes.
  public func setFrameIntervalNanos(_ nanos: UInt64) {
    frameIntervalNanos = nanos
  }

  /// Record a frame into the readiness state machine and evaluate the state.
  public func recordAndEvaluate(generation: Int, isStale: Bool, adjusting: Bool, monotonicNanos: UInt64) async -> ReadinessState {
    readiness.recordFrame(
      generation: generation, isStale: isStale, adjusting: adjusting,
      monotonicNanos: monotonicNanos)
  }
}
