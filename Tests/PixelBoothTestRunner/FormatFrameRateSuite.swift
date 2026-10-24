import CoreMedia
import Foundation
import PixelBoothCapture
import PixelBoothCore

func runFormatFrameRateSuite() async {
  suite("FormatFrameRates")

  await test("equalGeometryAndFourCCDoNotMergeDistinctFormats") {
    let slow = try rateTestDescription("slow")
    let fast = try rateTestDescription("fast")
    let advertised = [rateTestCapabilities(slow, 30), rateTestCapabilities(fast, 60)]
    check(
      FormatFrameRateCapabilities.matching(slow, current: nil, advertised: advertised)?
        .ranges.first?.maximum == 30,
      "slow format retains its own rates")
    check(
      FormatFrameRateCapabilities.matching(fast, current: nil, advertised: advertised)?
        .ranges.first?.maximum == 60,
      "fast format retains its own rates")
  }

  await test("missingAndAmbiguousMatchesRemainUnknown") {
    let description = try rateTestDescription("selected")
    let unrelated = try rateTestDescription("other")
    let capability = rateTestCapabilities(description, 30)
    check(
      FormatFrameRateCapabilities.matching(
        description, current: nil, advertised: [rateTestCapabilities(unrelated, 60)]) == nil,
      "same geometry is insufficient")
    check(
      FormatFrameRateCapabilities.matching(
        description, current: nil, advertised: [capability, capability]) == nil,
      "duplicate exact matches are ambiguous")
  }

  await test("currentCMIORatesOverrideOnlyTheirExactFormat") {
    let description = try rateTestDescription("selected")
    let unrelated = try rateTestDescription("other")
    let advertised = [rateTestCapabilities(description, 60)]
    check(
      FormatFrameRateCapabilities.matching(
        description, current: rateTestCapabilities(description, 30), advertised: advertised)?
        .ranges.first?.maximum == 30,
      "current CMIO supported range takes precedence")
    check(
      FormatFrameRateCapabilities.matching(
        description, current: rateTestCapabilities(unrelated, 15), advertised: advertised)?
        .ranges.first?.maximum == 60,
      "unrelated current format cannot overwrite advertised rates")
  }

  await test("invalidRatesStayUnknownAndFractionalRatesRemainExact") {
    let description = try rateTestDescription("selected")
    let invalid = FormatFrameRateCapabilities(
      formatDescription: description,
      ranges: [
        .init(minimum: 0, maximum: 30), .init(minimum: .nan, maximum: 30),
        .init(minimum: 30, maximum: .infinity), .init(minimum: 60, maximum: 30),
      ])
    check(
      FormatFrameRateCapabilities.matching(
        description, current: invalid, advertised: [invalid]) == nil,
      "invalid supported ranges cannot become display or configuration facts")
    let fractional = rateTestCapabilities(description, 30_000.0 / 1001)
    check(
      FormatFrameRateCapabilities.matching(
        description, current: invalid, advertised: [fractional])?.ranges == fractional.ranges,
      "invalid CMIO ranges fall back to the exact advertised fractional rate")
  }

  await test("refreshPreservesSelectionIdentityAndRejectsOtherFormats") {
    let description = try rateTestDescription("selected")
    let mode = mkMode(
      1920, 1080, PixelFormatFourCC.fourTwentyV, 0,
      formatID: CMIOCaptureDiscovery.formatIdentity(description))
    let refreshed = rateTestCapabilities(description, 60).updating(mode)
    check(refreshed.maxFrameRate == 60 && refreshed.minFrameRate == 5, "rates refreshed")
    check(refreshed.id == mode.id, "rate discovery never changes selection identity")
    check(
      ModeSelector.rememberedMode(id: mode.id, in: [refreshed]) == refreshed,
      "remembered selection survives the refresh")
    let unrelated = try rateTestDescription("other")
    check(
      rateTestCapabilities(unrelated, 120).updating(mode) == mode,
      "a stale refresh cannot change another representation")
  }
}

private func rateTestDescription(_ variant: String) throws -> CMFormatDescription {
  var description: CMFormatDescription?
  let status = CMVideoFormatDescriptionCreate(
    allocator: kCFAllocatorDefault, codecType: PixelFormatFourCC.fourTwentyV,
    width: 1920, height: 1080,
    extensions: ["PixelBoothTestVariant": variant] as CFDictionary,
    formatDescriptionOut: &description)
  guard status == noErr, let description else {
    throw NSError(domain: "FormatFrameRateFixture", code: Int(status))
  }
  return description
}

private func rateTestCapabilities(
  _ description: CMFormatDescription, _ maximum: Double
) -> FormatFrameRateCapabilities {
  FormatFrameRateCapabilities(
    formatDescription: description, ranges: [.init(minimum: 5, maximum: maximum)])
}
