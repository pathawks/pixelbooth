import Foundation

/// Thread-safe revision token checked inside backend operations that suspend.
/// The main-actor owner publishes a new revision before awaiting a backend, so
/// an obsolete CMIO negotiation can stop before installing stream state.
public final class CaptureConfigurationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var revision = 0

  public init() {}

  public func publish(_ revision: Int) {
    lock.lock()
    self.revision = revision
    lock.unlock()
  }

  public func isCurrent(_ revision: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.revision == revision
  }
}

/// Serializes backend configure/start/stop sequences while they await CMIO or
/// AVFoundation. A newer owner revision may supersede a held operation, but it
/// cannot interleave a stop or start with that operation.
public actor CaptureBackendOperationGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public func withExclusive<Value: Sendable>(
    _ operation: @MainActor @Sendable () async throws -> Value
  ) async rethrows -> Value {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    guard isHeld else {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
