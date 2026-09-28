import Foundation

/// Readiness state machine. Combines frame freshness counts, wall-clock time
/// since valid streaming began, and — where the camera actually exposes them —
/// real exposure/focus/white-balance convergence. Otherwise it runs the
/// explicitly labeled heuristic. A legitimately dark picture is never treated
/// as "invalid".
public struct ReadinessStateMachine {
  public var heuristic: ReadinessHeuristic

  /// Monotonic clock start of the current valid streaming run.
  private var validStartNanos: UInt64?
  private var freshValidFrameCount: Int = 0
  private var lastGeneration: Int = -1

  public init(heuristic: ReadinessHeuristic = .default) {
    self.heuristic = heuristic
  }

  /// Call when a mode change or reconnection invalidates prior state.
  public mutating func reset() {
    validStartNanos = nil
    freshValidFrameCount = 0
    lastGeneration = -1
  }

  /// Record a frame arriving with the given generation tag and freshness.
  /// - Parameter frameGeneration: configuration generation of the frame.
  /// - Parameter isStale: true if the frame's timestamp predates the
  ///   current configuration or is otherwise outside the freshness window.
  /// - Parameter adjusting: true if the camera reports it is still adjusting
  ///   exposure/focus/white balance (only when the device actually exposes
  ///   this; the caller must not invent it).
  public mutating func recordFrame(
    generation: Int,
    isStale: Bool,
    adjusting: Bool,
    monotonicNanos: UInt64
  ) -> ReadinessState {
    if generation != lastGeneration {
      if lastGeneration != -1 && generation > lastGeneration {
        reset()
      }
      lastGeneration = generation
    }
    if isStale {
      // Stale frames do not count as fresh or extend the validity window.
      return currentState(monotonicNanos: monotonicNanos, adjusting: adjusting)
    }
    if validStartNanos == nil {
      validStartNanos = monotonicNanos
    }
    freshValidFrameCount += 1
    return currentState(monotonicNanos: monotonicNanos, adjusting: adjusting)
  }

  /// Snapshot the readiness state without recording a frame.
  public func currentState(monotonicNanos: UInt64, adjusting: Bool) -> ReadinessState {
    guard let start = validStartNanos else { return .noStream }
    let msSince = Int((monotonicNanos &- start) / 1_000_000)
    if freshValidFrameCount < heuristic.minimumFreshFrames
      || msSince < heuristic.minimumMillisecondsSinceValidStart
    {
      return .warmingUp(
        framesNeeded: max(0, heuristic.minimumFreshFrames - freshValidFrameCount),
        msSinceStart: msSince,
        adjusting: adjusting)
    }
    if adjusting {
      if msSince >= heuristic.maximumAdjustingWaitMilliseconds {
        return .stillAdjusting(exceededMs: msSince)
      }
      return .warmingUp(
        framesNeeded: 0,
        msSinceStart: msSince,
        adjusting: true)
    }
    return .ready
  }

  public var isReady: Bool {
    validStartNanos != nil && freshValidFrameCount >= heuristic.minimumFreshFrames
  }
}

/// Frame freshness: the host-observed age of the frame at evaluation time,
/// derived from the monotonic delivery timestamp and the frame rate — not
/// callback counts, and not a comparison against whichever frame happened to
/// arrive last. A stopped stream must go stale as wall time elapses; comparing
/// frames only with the newest delivered frame can never do that because the
/// newest frame stays equal to itself forever.
public enum FrameFreshness {
  /// The frame is fresh if the host observed it within one frame-interval plus
  /// a small allowance of `nowNanos`.
  public static func isFresh(
    frameObservedNanos: UInt64, nowNanos: UInt64, frameIntervalNanos: UInt64
  ) -> Bool {
    // 1.5× the frame interval covers scheduling jitter without accepting
    // genuinely stale content.
    let allowance = frameIntervalNanos + frameIntervalNanos / 2
    return nowNanos >= frameObservedNanos && (nowNanos &- frameObservedNanos) <= allowance
  }
}
