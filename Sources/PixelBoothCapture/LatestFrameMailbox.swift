import Foundation

/// A single pending slot for independently decodable camera frames.
///
/// Producers replace a frame that has not started processing yet, so a slow
/// consumer works on the current image instead of falling farther behind the
/// camera. H.264 must not use this mailbox because dropping an encoded sample
/// can break decoder dependencies.
public final class LatestFrameMailbox<Value: Sendable>: @unchecked Sendable {
  // The lock protects both the pending value and the single-drainer state.
  // No user code runs while the lock is held.
  private let lock = NSLock()
  private var pendingValue: Value?
  private var hasDrainer = false

  public init() {}

  /// Stores the newest value and returns true only when the caller must start
  /// the mailbox's drain loop.
  @discardableResult
  public func offer(_ value: Value) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    pendingValue = value
    guard !hasDrainer else { return false }
    hasDrainer = true
    return true
  }

  /// Returns the newest pending value. A nil result ends the current drain
  /// loop and makes the next offer responsible for scheduling another one.
  public func takeNext() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = pendingValue else {
      hasDrainer = false
      return nil
    }
    pendingValue = nil
    return value
  }
}

/// Bounded admission for a sink that must retain a small amount of work before
/// dispatch. Independent images keep the newest frame; dependency streams keep
/// decode order and, after overflow, wait for a random-access frame.
public final class FrameAdmissionMailbox<Value: Sendable>: @unchecked Sendable {
  public enum Policy: Sendable {
    case latest(maximumBytes: Int)
    case dependencyPreserving(maximumFrames: Int, maximumBytes: Int)
  }

  public struct Delivery: Sendable {
    public let value: Value
    public let byteCount: Int
    public let requiresDecoderReset: Bool
  }

  public struct OfferResult: Sendable, Equatable {
    public let shouldScheduleDrain: Bool
    public let droppedFrames: Int
    public let overflowedDependencies: Bool
    public let refusedOversizedFrame: Bool
  }

  private let lock = NSLock()
  private let policy: Policy
  private var pending: [Delivery] = []
  private var pendingBytes = 0
  private var hasDrainer = false
  private var waitingForRandomAccessFrame = false

  public init(policy: Policy) {
    self.policy = policy
    if case .dependencyPreserving = policy { waitingForRandomAccessFrame = true }
  }

  @discardableResult
  public func offer(
    _ value: Value, byteCount: Int, isRandomAccessFrame: Bool = false
  ) -> OfferResult {
    lock.lock()
    defer { lock.unlock() }
    guard byteCount >= 0 else {
      return OfferResult(
        shouldScheduleDrain: false, droppedFrames: 1,
        overflowedDependencies: false, refusedOversizedFrame: true)
    }
    let wasDraining = hasDrainer
    var dropped = 0
    var overflowedDependencies = false
    var refusedOversizedFrame = false

    switch policy {
    case .latest(let maximumBytes):
      guard byteCount <= maximumBytes else {
        refusedOversizedFrame = true
        dropped = 1
        break
      }
      dropped = pending.count
      pending.removeAll(keepingCapacity: true)
      pendingBytes = byteCount
      pending.append(Delivery(value: value, byteCount: byteCount, requiresDecoderReset: false))
    case .dependencyPreserving(let maximumFrames, let maximumBytes):
      guard maximumFrames > 0, maximumBytes > 0, byteCount <= maximumBytes else {
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        waitingForRandomAccessFrame = true
        overflowedDependencies = true
        refusedOversizedFrame = true
        dropped = 1
        break
      }
      if waitingForRandomAccessFrame {
        guard isRandomAccessFrame else {
          return OfferResult(
            shouldScheduleDrain: false, droppedFrames: 1,
            overflowedDependencies: false, refusedOversizedFrame: false)
        }
        waitingForRandomAccessFrame = false
        pending.append(
          Delivery(value: value, byteCount: byteCount, requiresDecoderReset: true))
        pendingBytes = byteCount
      } else if pending.count >= maximumFrames || byteCount > maximumBytes - pendingBytes {
        dropped = pending.count + 1
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        waitingForRandomAccessFrame = true
        overflowedDependencies = true
        if isRandomAccessFrame {
          waitingForRandomAccessFrame = false
          pending.append(
            Delivery(value: value, byteCount: byteCount, requiresDecoderReset: true))
          pendingBytes = byteCount
        }
      } else {
        pending.append(
          Delivery(value: value, byteCount: byteCount, requiresDecoderReset: false))
        pendingBytes += byteCount
      }
    }

    if !pending.isEmpty { hasDrainer = true }
    return OfferResult(
      shouldScheduleDrain: !wasDraining && hasDrainer,
      droppedFrames: dropped,
      overflowedDependencies: overflowedDependencies,
      refusedOversizedFrame: refusedOversizedFrame)
  }

  public func takeNext() -> Delivery? {
    lock.lock()
    defer { lock.unlock() }
    guard !pending.isEmpty else {
      hasDrainer = false
      return nil
    }
    let delivery = pending.removeFirst()
    pendingBytes -= delivery.byteCount
    return delivery
  }

  public func reset() {
    lock.lock()
    pending.removeAll(keepingCapacity: false)
    pendingBytes = 0
    hasDrainer = false
    if case .dependencyPreserving = policy { waitingForRandomAccessFrame = true }
    lock.unlock()
  }

  public var retainedFrameCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pending.count
  }

  public var retainedByteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pendingBytes
  }
}
