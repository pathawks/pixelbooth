// Freshness suite: host-monotonic age-based freshness (a stopped stream must
// go stale), bounded shutter waiting, and store invalidation when delivery
// stops. Synthetic sample buffers only; no camera required.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import Synchronization

private enum FreshnessTestError: Error { case setup(String) }

private final class FreshnessTestClock: Sendable {
  private let nanos = Mutex<UInt64>(1_000_000_000)

  var now: UInt64 { nanos.withLock { $0 } }

  func advance(by delta: UInt64) {
    nanos.withLock { $0 += delta }
  }
}

private func makeFrame(
  deviceID: String = "fixture",
  generation: Int = 1,
  observedNanos: UInt64,
  mediaNanos: UInt64 = 1
) throws -> DeliveredFrame {
  var pixelBuffer: CVPixelBuffer?
  guard
    CVPixelBufferCreate(
      kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
      nil, &pixelBuffer) == kCVReturnSuccess,
    let pixelBuffer
  else {
    throw FreshnessTestError.setup("CVPixelBufferCreate")
  }
  var formatDescription: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription) == noErr,
    let formatDescription
  else {
    throw FreshnessTestError.setup("CMVideoFormatDescriptionCreateForImageBuffer")
  }
  var timing = CMSampleTimingInfo(
    duration: .invalid,
    presentationTimeStamp: mediaNanos > 0
      ? CMTime(value: Int64(mediaNanos), timescale: 1_000_000_000) : .invalid,
    decodeTimeStamp: .invalid)
  var sampleBuffer: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: formatDescription, sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer) == noErr,
    let sampleBuffer
  else {
    throw FreshnessTestError.setup("CMSampleBufferCreateReadyWithImageBuffer")
  }
  return DeliveredFrame(
    sampleBuffer: sampleBuffer,
    generation: generation,
    deviceUniqueID: deviceID,
    fourCC: kCVPixelFormatType_32BGRA,
    width: 2,
    height: 2,
    timestampNanos: mediaNanos,
    hostMonotonicNanos: observedNanos,
    hostWallClockISO: "2026-09-22T12:00:00Z")
}

func runFreshnessSuite() async {
  suite("Freshness")

  await test("latestFrameMailboxBoundsPendingUncompressedWork") {
    let mailbox = LatestFrameMailbox<Int>()
    let shouldStartDrain = mailbox.offer(1)
    let scheduledAgain = mailbox.offer(2)
    check(shouldStartDrain, "first frame schedules one drain loop")
    check(!scheduledAgain, "new frames replace the one pending value")
    check(mailbox.takeNext() == 2, "drain loop receives the newest pending frame")

    let scheduledWhileProcessing = mailbox.offer(3)
    let replacedWhileProcessing = mailbox.offer(4)
    check(!scheduledWhileProcessing && !replacedWhileProcessing, "active drain remains unique")
    check(mailbox.takeNext() == 4, "only the newest waiting frame remains pending")
    check(mailbox.takeNext() == nil, "empty mailbox ends the drain loop")

    check(mailbox.offer(5), "a later frame starts a fresh drain loop")
    check(mailbox.takeNext() == 5, "the later frame is preserved")
    check(mailbox.takeNext() == nil, "the restarted drain loop terminates")
  }

  // Regression: one frame arrives, then delivery stops. The last frame's
  // media timestamp and the store's newest observed timestamp stay equal
  // forever, so comparing frames only with each other kept reporting fresh
  // after 600 ms. Age against the host monotonic clock must go stale.
  await test("stoppedDeliveryGoesStaleWithElapsedTime") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let frame = try makeFrame(observedNanos: DispatchTime.now().uptimeNanoseconds)
    let stored = await store.store(frame)
    check(stored, "frame is stored for the active configuration")
    let freshOnArrival = await store.freshFrameAvailable()
    check(freshOnArrival, "a just-delivered frame is fresh")

    try? await Task.sleep(nanoseconds: 600_000_000)
    let freshAfterStop = await store.freshFrameAvailable()
    check(!freshAfterStop, "600 ms after the last frame, freshness must be false")
    let selected = await store.newestFreshFrame(timeoutNanos: 50_000_000)
    check(selected == nil, "a stopped stream must not satisfy the shutter")
  }

  await test("waitingShutterAcceptsResumedDelivery") {
    let store = FrameStore()
    let clock = FreshnessTestClock()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let stale = try makeFrame(
      observedNanos: clock.now - 1_000_000_000)
    let staleStored = await store.store(stale)
    check(staleStored, "stale frame stored")

    // Resume only after the shutter has found no eligible frame and suspended.
    // Controlled time keeps a busy CI executor from aging out this single frame.
    let fresh = try makeFrame(observedNanos: clock.now + 80_000_000, mediaNanos: 2)
    let selected = await store.newestFreshFrame(
      timeoutNanos: 1_000_000_000,
      nowNanos: { clock.now },
      waitForNextPoll: {
        clock.advance(by: 80_000_000)
        let stored = await store.store(fresh)
        check(stored, "resumed frame is stored during the shutter wait")
      })
    check(selected?.timestampNanos == 2, "the resumed frame satisfies the waiting shutter")
    check(clock.now == 1_080_000_000, "the shutter selects on the first poll after delivery")
    if let selected {
      let freshAtSelection = await store.isFresh(selected, nowNanos: clock.now)
      check(freshAtSelection, "selected frame is fresh at selection time")
    }
  }

  await test("waitingShutterTimesOutWithoutFreshDelivery") {
    let store = FrameStore()
    let clock = FreshnessTestClock()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let stale = try makeFrame(observedNanos: clock.now - 1_000_000_000)
    _ = await store.store(stale)

    let selected = await store.newestFreshFrame(
      timeoutNanos: 1_000_000_000,
      nowNanos: { clock.now },
      waitForNextPoll: { clock.advance(by: 100_000_000) })
    check(selected == nil, "stale delivery never satisfies the shutter")
    check(clock.now == 2_000_000_000, "waiting ends at the configured deadline")
  }

  await test("waitingShutterRejectsDeliveryThatExpiresBeforeNextPoll") {
    let store = FrameStore()
    let clock = FreshnessTestClock()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let resumed = try makeFrame(observedNanos: clock.now + 80_000_000, mediaNanos: 2)

    let selected = await store.newestFreshFrame(
      timeoutNanos: 1_000_000_000,
      nowNanos: { clock.now },
      waitForNextPoll: {
        if clock.now == 1_000_000_000 {
          clock.advance(by: 80_000_000)
          _ = await store.store(resumed)
          // Simulate the selection task resuming after this frame has expired.
          clock.advance(by: 120_000_000)
        } else {
          clock.advance(by: 100_000_000)
        }
      })
    check(selected == nil, "a frame that expires while the shutter waits is rejected")
    check(clock.now == 2_000_000_000, "expired delivery does not extend the deadline")
  }

  await test("invalidateDropsFramesAndRejectsLateDelivery") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let frame = try makeFrame(observedNanos: DispatchTime.now().uptimeNanoseconds)
    let stored = await store.store(frame)
    check(stored, "frame stored before invalidation")

    await store.invalidate()
    let freshAfterInvalidate = await store.freshFrameAvailable()
    check(!freshAfterInvalidate, "invalidate drops retained frames")
    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(selected == nil, "no frame is available after invalidation")

    // A frame already queued toward the store when delivery stopped must not
    // enter after the invalidation.
    let lateStored = await store.store(frame)
    check(!lateStored, "late frame from the invalidated stream is rejected")

    await store.beginConfiguration(
      deviceID: "fixture", generation: 2,
      frameIntervalNanos: 33_333_333)
    let replacement = try makeFrame(
      generation: 2, observedNanos: DispatchTime.now().uptimeNanoseconds)
    let replacementStored = await store.store(replacement)
    check(replacementStored, "a new configuration accepts frames again")
  }

  await test("staleStopDoesNotInvalidateReplacementStream") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    // A replacement stream is configured before the old stream's stop event
    // reaches the store.
    await store.beginConfiguration(
      deviceID: "fixture", generation: 2,
      frameIntervalNanos: 33_333_333)
    let frame = try makeFrame(
      generation: 2, observedNanos: DispatchTime.now().uptimeNanoseconds)
    _ = await store.store(frame)

    let staleInvalidated = await store.invalidateIfActive(deviceID: "fixture", generation: 1)
    check(!staleInvalidated, "stop for an already-replaced stream is ignored")
    let replacementSurvives = await store.freshFrameAvailable()
    check(replacementSurvives, "replacement stream's frame survives a stale stop")

    let activeInvalidated = await store.invalidateIfActive(deviceID: "fixture", generation: 2)
    check(activeInvalidated, "stop for the active stream invalidates it")
    let freshAfterActiveStop = await store.freshFrameAvailable()
    check(!freshAfterActiveStop, "active stream's frames are dropped")
  }

  await test("previousConfigurationAndDeviceFramesRejected") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 2,
      frameIntervalNanos: 33_333_333)
    let oldGeneration = try makeFrame(
      generation: 1, observedNanos: DispatchTime.now().uptimeNanoseconds)
    let oldStored = await store.store(oldGeneration)
    check(!oldStored, "frame from a previous configuration is rejected")

    let otherDevice = try makeFrame(
      deviceID: "other", generation: 2,
      observedNanos: DispatchTime.now().uptimeNanoseconds)
    let otherStored = await store.store(otherDevice)
    check(!otherStored, "frame from another device is rejected")
  }

  // The active configuration is explicit: without one, nothing is accepted.
  // A store that appends "every frame" lets a callback delivered before the
  // first/next configuration become selectable.
  await test("unconfiguredStoreRejectsEveryFrame") {
    let store = FrameStore()
    let frame = try makeFrame(observedNanos: DispatchTime.now().uptimeNanoseconds)
    let stored = await store.store(frame)
    check(!stored, "a store with no active configuration rejects frames")
    let current = await store.isCurrentGeneration(frame)
    check(!current, "no frame is current without an explicit active configuration")
    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(selected == nil, "an unconfigured store has nothing to select")
    let config = await store.activeConfiguration
    check(config == nil, "the active configuration starts unset")

    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let configured = await store.activeConfiguration
    check(
      configured
        == FrameStore.ActiveConfiguration(
          deviceUniqueID: "fixture", generation: 1, frameIntervalNanos: 33_333_333),
      "beginConfiguration sets the active configuration explicitly")
  }

  // Reproduced regression: store generation 2, then a delayed generation-1
  // callback arrives only 1 ms "older". Because frame counts as `frames.last`
  // (and because selection used callback order), the shutter selected the
  // obsolete generation. The active configuration must decide instead.
  await test("delayedObsoleteGenerationCannotBeSelected") {
    let store = FrameStore()
    // Wide freshness window: this test is about generation identity, not age.
    await store.beginConfiguration(
      deviceID: "fixture", generation: 2,
      frameIntervalNanos: 1_000_000_000)
    let now = DispatchTime.now().uptimeNanoseconds
    let current = try makeFrame(
      generation: 2, observedNanos: now, mediaNanos: 2_000_000_000)
    let currentStored = await store.store(current)
    check(currentStored, "active-configuration frame is stored")

    let delayed = try makeFrame(
      generation: 1, observedNanos: now + 1_000_000, mediaNanos: 1_999_000_000)
    let delayedStored = await store.store(delayed)
    check(!delayedStored, "a delayed frame from the replaced configuration is rejected")

    let delayedCurrent = await store.isCurrentGeneration(delayed)
    check(!delayedCurrent, "the obsolete frame is not current just because it arrived last")

    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(selected?.generation == 2, "the shutter selects the active configuration")
    check(
      selected?.timestampNanos == 2_000_000_000,
      "the shutter does not select the delayed obsolete callback")
  }

  // Reconfiguration clears retained frames and rejects callbacks already
  // queued toward the store when delivery was replaced.
  await test("reconfigurationDropsFramesAndRejectsQueuedCallbacks") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let queued = try makeFrame(observedNanos: DispatchTime.now().uptimeNanoseconds)
    await store.beginConfiguration(
      deviceID: "fixture", generation: 2,
      frameIntervalNanos: 60_000_000)
    let queuedStored = await store.store(queued)
    check(!queuedStored, "a callback queued before reconfiguration is rejected after it")
    let queuedCurrent = await store.isCurrentGeneration(queued)
    check(!queuedCurrent, "the queued callback is not current after reconfiguration")
    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(selected == nil, "the replaced stream's frame cannot satisfy the shutter")
  }

  // Selection must follow the camera's presentation clock, not callback
  // arrival order: H.264 decode order can deliver a newer picture, then an
  // older one. Appending cannot reorder them into "newest".
  await test("selectionUsesPresentationTimeNotCallbackOrder") {
    let store = FrameStore()
    // Wide freshness window: this test is about ordering, not age.
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 1_000_000_000)
    let base = DispatchTime.now().uptimeNanoseconds - 1_000_000
    let newer = try makeFrame(observedNanos: base, mediaNanos: 2_000_000_000)
    let lateOlder = try makeFrame(observedNanos: base + 10_000, mediaNanos: 1_999_000_000)
    let newerStored = await store.store(newer)
    let lateStored = await store.store(lateOlder)
    check(newerStored && lateStored, "both same-configuration frames are stored")

    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(
      selected?.timestampNanos == 2_000_000_000,
      "the newer presentation timestamp wins over the later callback")
  }

  // A stale frame cannot satisfy the shutter even when it is the newest
  // callback or carries the newest presentation timestamp.
  await test("selectionIgnoresStaleFramesWithNewerPresentationTime") {
    let store = FrameStore()
    await store.beginConfiguration(
      deviceID: "fixture", generation: 1,
      frameIntervalNanos: 33_333_333)
    let now = DispatchTime.now().uptimeNanoseconds
    let stale = try makeFrame(observedNanos: now - 1_000_000_000, mediaNanos: 3_000_000_000)
    let fresh = try makeFrame(observedNanos: now, mediaNanos: 2_999_000_000)
    _ = await store.store(stale)
    _ = await store.store(fresh)

    let freshAvailable = await store.freshFrameAvailable()
    check(
      freshAvailable, "a fresh frame exists even though a stale frame has a newer timestamp")
    let selected = await store.newestFreshFrame(timeoutNanos: 0)
    check(
      selected?.timestampNanos == 2_999_000_000,
      "a stale frame cannot satisfy the shutter even with a newer presentation time")
  }
}
