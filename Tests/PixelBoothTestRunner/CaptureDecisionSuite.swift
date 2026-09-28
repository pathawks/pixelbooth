import PixelBoothCore

func runCaptureDecisionSuite() async {
  suite("CaptureDecision")

  await test("readinessBlocksButUnknownUpstreamDoesNot") {
    let warming = CaptureEligibilityDecision.evaluate(
      isFresh: true, readiness: .warmingUp(framesNeeded: 7, msSinceStart: 0, adjusting: false),
      formatIsValid: true)
    check(
      warming
        == .waitingForReadiness(
          .warmingUp(
            framesNeeded: 7, msSinceStart: 0, adjusting: false)), "warm-up blocks the shutter")

    let unknownUpstream = CaptureEligibilityDecision.evaluate(
      isFresh: true, readiness: .ready, formatIsValid: true)
    check(unknownUpstream == .eligible, "valid frame with unknown upstream can be captured")
  }

  await test("staleAndInvalidFramesRemainBlocked") {
    let stale = CaptureEligibilityDecision.evaluate(
      isFresh: false, readiness: .ready, formatIsValid: true)
    let invalid = CaptureEligibilityDecision.evaluate(
      isFresh: true, readiness: .ready, formatIsValid: false)
    check(stale == .staleFrame, "stale frames cannot be captured")
    check(invalid == .rejectedFormat, "known format violations cannot be captured")
  }

  await test("configurationChangesStillInvalidateEligibility") {
    var state = CaptureEligibilityState()
    let firstDelivery = "camera#7#selected=420v#delivered=NV12"
    state.selectConfiguration(firstDelivery)
    let first = state.decision(
      configurationKey: firstDelivery, isFresh: true, readiness: .ready,
      formatIsValid: true)
    check(first == .eligible, "current valid delivery is eligible without acknowledgment")

    let changedDelivery = "camera#7#selected=420v#delivered=420v"
    state.selectConfiguration(changedDelivery)
    let changed = state.decision(
      configurationKey: changedDelivery, isFresh: true, readiness: .ready,
      formatIsValid: true)
    check(changed == .eligible, "new valid delivery is eligible without acknowledgment")

    let missingConfiguration = state.decision(
      configurationKey: "obsolete-camera-mode", isFresh: true, readiness: .ready,
      formatIsValid: true)
    check(missingConfiguration == .staleFrame, "obsolete config cannot become eligible")
  }

  await test("highestRateAcrossDiscreteRanges") {
    let ranges = [15.0, 30.0, 60.0].map {
      SupportedFrameRateRange(minimum: $0, maximum: $0)
    }
    check(
      FrameRateSelection.highestSupported(in: ranges, ceiling: 60) == 60,
      "the maximum advertised discrete rate wins")
    check(
      FrameRateSelection.highestSupported(in: ranges, ceiling: 45) == 30,
      "an explicit ceiling chooses the highest rate beneath it")
  }
}
