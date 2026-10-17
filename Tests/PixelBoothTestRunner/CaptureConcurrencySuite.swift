import AVFoundation
import Foundation
import PixelBoothCapture

private actor SuiteLatch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private actor GateEventRecorder {
  private var events: [String] = []
  private var activeOperations = 0
  private var maximumActiveOperations = 0

  func begin(_ name: String) {
    events.append(name)
    activeOperations += 1
    maximumActiveOperations = max(maximumActiveOperations, activeOperations)
  }

  func append(_ name: String) { events.append(name) }

  func end() { activeOperations -= 1 }

  func snapshot() -> (events: [String], maximumActive: Int) {
    (events, maximumActiveOperations)
  }
}

private final class PreviewSessionFixtures: @unchecked Sendable {
  // Immutable session references are shared only so concurrent holder access
  // can be exercised without starting a camera or mutating a session.
  let sessions = (0..<8).map { _ in AVCaptureSession() }
}

private final class LockedFlag: @unchecked Sendable {
  // A synchronous DispatchQueue stress callback records one test failure bit.
  private let lock = NSLock()
  private var storage = false

  func set() {
    lock.lock()
    storage = true
    lock.unlock()
  }

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

func runCaptureConcurrencySuite() async {
  suite("CaptureConcurrency")

  await test("backend gate serializes superseded configure and replacement") {
    let gate = CaptureBackendOperationGate()
    let token = CaptureConfigurationToken()
    token.publish(1)
    let recorder = GateEventRecorder()
    let oldOperationEntered = SuiteLatch()
    let releaseOldOperation = SuiteLatch()

    let oldOperation = Task {
      await gate.withExclusive {
        await recorder.begin("configure-A")
        await oldOperationEntered.open()
        await releaseOldOperation.wait()
        if token.isCurrent(1) {
          await recorder.append("start-A")
        } else {
          await recorder.append("A-superseded")
        }
        await recorder.end()
      }
    }
    await oldOperationEntered.wait()
    token.publish(2)
    let replacementOperation = Task {
      await gate.withExclusive {
        await recorder.begin("stop-B")
        await recorder.append("configure-B")
        await recorder.end()
      }
    }

    await releaseOldOperation.open()
    await oldOperation.value
    await replacementOperation.value
    let result = await recorder.snapshot()
    check(
      result.events == ["configure-A", "A-superseded", "stop-B", "configure-B"],
      "an obsolete operation does not start after a newer selection")
    check(result.maximumActive == 1, "backend operations never overlap")
  }

  await test("frame admission bounds independent and dependent retained work") {
    let independent = FrameAdmissionMailbox<Int>(policy: .latest(maximumBytes: 8))
    for value in 0..<100 {
      _ = independent.offer(value, byteCount: 4)
    }
    check(independent.retainedFrameCount == 1, "independent samples coalesce to one pending frame")
    check(independent.retainedByteCount == 4, "coalesced memory stays within its byte limit")
    check(independent.takeNext()?.value == 99, "the latest independent sample is retained")
    check(independent.retainedByteCount == 0, "draining releases retained-byte accounting")

    let dependent = FrameAdmissionMailbox<Int>(
      policy: .dependencyPreserving(maximumFrames: 3, maximumBytes: 10))
    _ = dependent.offer(1, byteCount: 3, isRandomAccessFrame: false)
    let firstSync = dependent.offer(2, byteCount: 4, isRandomAccessFrame: true)
    _ = dependent.offer(3, byteCount: 3)
    _ = dependent.offer(4, byteCount: 3)
    let overflow = dependent.offer(5, byteCount: 1)
    check(firstSync.shouldScheduleDrain, "a valid H.264 synchronization point starts delivery")
    check(overflow.overflowedDependencies, "overflow invalidates the retained dependency chain")
    check(dependent.retainedFrameCount == 0, "dependent overflow clears undecodable queued frames")
    check(dependent.retainedByteCount == 0, "dependent overflow releases queued sample bytes")
    _ = dependent.offer(6, byteCount: 2, isRandomAccessFrame: false)
    _ = dependent.offer(7, byteCount: 4, isRandomAccessFrame: true)
    check(
      dependent.retainedFrameCount == 1, "post-overflow delivery waits for a random-access frame")
    check(dependent.retainedByteCount == 4, "post-overflow bytes remain under the configured bound")
    let resumed = dependent.takeNext()
    check(resumed?.value == 7, "only the recovered synchronization frame is delivered")
    check(resumed?.requiresDecoderReset == true, "decoder reset is attached to the recovered frame")
  }

  await test("preview session holder synchronizes replacement and lifetime") {
    let holder = PreviewSessionHolder()
    let oldSession = AVCaptureSession()
    let currentSession = AVCaptureSession()
    holder.install(oldSession)
    holder.install(currentSession)
    holder.clear(ifMatching: oldSession)
    check(holder.current() === currentSession, "clearing an old session preserves its replacement")

    weak var retainedSession: AVCaptureSession?
    do {
      let temporarySession = AVCaptureSession()
      retainedSession = temporarySession
      holder.install(temporarySession)
    }
    check(retainedSession != nil, "the synchronized holder owns its installed session")
    if let retainedSession { holder.clear(ifMatching: retainedSession) }
    check(holder.current() == nil, "clearing releases the held session")

    let fixtures = PreviewSessionFixtures()
    let observedMissingSession = LockedFlag()
    DispatchQueue.concurrentPerform(iterations: 2_000) { index in
      let session = fixtures.sessions[index % fixtures.sessions.count]
      holder.install(session)
      if let current = holder.current(), !fixtures.sessions.contains(where: { $0 === current }) {
        observedMissingSession.set()
      }
      holder.clear(ifMatching: session)
    }
    check(!observedMissingSession.value, "concurrent reads return only installed session objects")
    if let current = holder.current() { holder.clear(ifMatching: current) }
    check(holder.current() == nil, "the synchronized holder releases its final session")
  }
}
