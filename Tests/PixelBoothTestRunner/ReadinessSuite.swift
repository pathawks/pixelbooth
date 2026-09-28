// Readiness state machine tests: warm-up thresholds, adjusting timeouts,
// stale-frame rejection, and mode-generation resets.

import PixelBoothCore

func runReadinessSuite() async {
  suite("Readiness")

  await test("minimumTimeBlocksCaptureAfterFrameCount") {
    var sm = ReadinessStateMachine()
    let start: UInt64 = 1_000_000_000
    var state: ReadinessState = .noStream
    for i in 0..<8 {
      state = sm.recordFrame(
        generation: 1, isStale: false, adjusting: false,
        monotonicNanos: start + UInt64(i) * 33_333_333)
    }
    // 8 frames but only ~233 ms: still warming up.
    guard case .warmingUp = state else {
      recordFailure("expected warmingUp, got \(state)")
      return
    }
  }

  await test("readyAfterFrameAndTimeThresholds") {
    var sm = ReadinessStateMachine()
    let start: UInt64 = 1_000_000_000
    var state: ReadinessState = .noStream
    for i in 0..<25 {
      state = sm.recordFrame(
        generation: 1, isStale: false, adjusting: false,
        monotonicNanos: start + UInt64(i) * 33_333_333)
    }
    check(state == .ready, "ready after >8 frames and >500 ms")
  }

  await test("staleFramesDoNotStartReadinessWindow") {
    var sm = ReadinessStateMachine()
    let start: UInt64 = 1_000_000_000
    for i in 0..<20 {
      _ = sm.recordFrame(
        generation: 1, isStale: true, adjusting: false,
        monotonicNanos: start + UInt64(i) * 33_333_333)
    }
    let state = sm.currentState(monotonicNanos: start + 1_000_000_000, adjusting: false)
    guard case .noStream = state else {
      recordFailure("stale frames must not start validity window: \(state)")
      return
    }
  }

  await test("newGenerationResetsWarmup") {
    var sm = ReadinessStateMachine()
    let start: UInt64 = 1_000_000_000
    for i in 0..<30 {
      _ = sm.recordFrame(
        generation: 1, isStale: false, adjusting: false,
        monotonicNanos: start + UInt64(i) * 33_333_333)
    }
    let after = sm.recordFrame(
      generation: 2, isStale: false, adjusting: false,
      monotonicNanos: start + 2_000_000_000)
    guard case .warmingUp = after else {
      recordFailure("mode change must reset readiness: \(after)")
      return
    }
  }

  await test("adjustingStateTimesOutExplicitly") {
    var sm = ReadinessStateMachine()
    let start: UInt64 = 1_000_000_000
    for i in 0..<30 {
      _ = sm.recordFrame(
        generation: 1, isStale: false, adjusting: true,
        monotonicNanos: start + UInt64(i) * 33_333_333)
    }
    let state = sm.currentState(monotonicNanos: start + 6_000_000_000, adjusting: true)
    guard case .stillAdjusting = state else {
      recordFailure("expected stillAdjusting after 5s: \(state)")
      return
    }
  }

  await test("freshnessUsesHostMonotonicAge") {
    let interval: UInt64 = 33_333_333
    let observed: UInt64 = 2_000_000_000
    check(
      FrameFreshness.isFresh(
        frameObservedNanos: observed, nowNanos: observed, frameIntervalNanos: interval),
      "just-observed frame fresh")
    check(
      FrameFreshness.isFresh(
        frameObservedNanos: observed, nowNanos: observed + interval, frameIntervalNanos: interval),
      "one frame interval old still fresh")
    check(
      !FrameFreshness.isFresh(
        frameObservedNanos: observed, nowNanos: observed + interval * 2,
        frameIntervalNanos: interval), "two intervals old stale")
    check(
      !FrameFreshness.isFresh(
        frameObservedNanos: observed + 1, nowNanos: observed, frameIntervalNanos: interval),
      "observation later than now is not fresh")
  }
}
