import Foundation
import ImageIO
import PixelBoothMetadata

private enum PortraitMetadataAssertion: Error { case failed(String) }

private func portraitMetadataPacket(_ intent: PortraitRenderIntent? = nil) -> [UInt8] {
  PixelBoothXMP.build(
    captureUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    appVersion: "test", captureBackend: "synthetic-test", backendVersion: "test",
    libavifVersion: "test", actualCaptureFormat: "synthetic native samples",
    encoderSettings: "lossless",
    metadataProvenance: [
      MetadataObservation(key: "fixture", rawValueString: "retained", provenance: .hostObserved)
    ], fidelity: "unknown", hostLocation: nil, mediaTimeNanos: 123,
    wallClockAnchorISO: "2026-10-22T12:00:00Z", portraitRenderIntent: intent)
}

private func portraitMetadataValue(_ metadata: CGImageMetadata, _ path: String) -> String? {
  CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
}

func runPortraitMetadataSuite() async {
  suite("PortraitMetadata")

  await test("defaultIntentRoundTripsWithExplicitApplicationOrigin") {
    let intent = try PortraitRenderIntent(primaryWidth: 4032, primaryHeight: 3024)
    check(intent.version == 1, "profile version explicit")
    check(intent.origin == .applicationDefault, "default origin explicit")
    check(intent.simulatedAperture == 2.8, "simulated aperture is an application choice")
    check(intent.focusCenterX == 0.5 && intent.focusCenterY == 0.5, "center focus policy")
    check(intent.focusWidth == 0.1 && intent.focusHeight == 0.1, "default region extent")
    let data = try JSONEncoder().encode(intent)
    check(
      try JSONDecoder().decode(PortraitRenderIntent.self, from: data) == intent,
      "validated intent survives durable JSON")
  }

  await test("unsafeOrMislabeledIntentParametersAreRejected") {
    let invalid: [() throws -> PortraitRenderIntent] = [
      { try PortraitRenderIntent(primaryWidth: 0, primaryHeight: 2) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: -1) },
      { try PortraitRenderIntent(primaryWidth: Int.max, primaryHeight: 2) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, simulatedAperture: .nan) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, simulatedAperture: 0) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, simulatedAperture: 65) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, focusCenterX: .infinity) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, focusWidth: 0) },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, focusHeight: 1.1) },
      {
        try PortraitRenderIntent(
          primaryWidth: 2, primaryHeight: 2, focusCenterX: 0.05, focusWidth: 0.2,
          origin: .applicationChosen)
      },
      { try PortraitRenderIntent(primaryWidth: 2, primaryHeight: 2, simulatedAperture: 4) },
    ]
    for makeIntent in invalid { expectThrows(makeIntent, "invalid render intent rejected") }
    let boundary = try PortraitRenderIntent(
      primaryWidth: 2, primaryHeight: 2, simulatedAperture: 4,
      focusCenterX: 0.05, focusCenterY: 0.95, focusWidth: 0.1, focusHeight: 0.1,
      origin: .applicationChosen)
    check(boundary.origin == .applicationChosen, "explicit choices have honest provenance")
    let wideAperture = try PortraitRenderIntent(
      primaryWidth: 2, primaryHeight: 2, simulatedAperture: 0.95, origin: .applicationChosen)
    check(wideAperture.simulatedAperture == 0.95, "positive sub-f/1 render choices are retained")
  }

  await test("JSONDecodingEnforcesTheSameProfileContract") {
    let intent = try PortraitRenderIntent(primaryWidth: 640, primaryHeight: 480)
    let encoded = try JSONEncoder().encode(intent)
    let mutations: [(String, Any)] = [
      ("version", 2), ("primaryWidth", 0), ("primaryHeight", -1),
      ("simulatedAperture", 0), ("focusCenterX", 1), ("focusWidth", 0),
      ("origin", "camera-reported"), ("simulatedAperture", 4),
    ]
    for (key, value) in mutations {
      var document = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
      document[key] = value
      let invalid = try JSONSerialization.data(withJSONObject: document)
      expectThrows(
        { try JSONDecoder().decode(PortraitRenderIntent.self, from: invalid) },
        "decoded \(key) must satisfy the public initializer's contract")
    }
  }

  await test("primaryXMPContainsReadableFocusStructureAndApplicationProvenance") {
    for (width, height) in [(4000, 3000), (1200, 2000)] {
      let intent = try PortraitRenderIntent(primaryWidth: width, primaryHeight: height)
      let packet = portraitMetadataPacket(intent)
      guard let metadata = CGImageMetadataCreateFromXMPData(Data(packet) as CFData) else {
        throw PortraitMetadataAssertion.failed("ImageIO rejected generated primary XMP")
      }
      let values: [(String, String)] = [
        ("pbx:PortraitProfileVersion", "1"),
        ("pbx:PortraitRenderIntentOrigin", "application-default"),
        ("pbx:PortraitRenderIntentRole", "external-rendering-instructions"),
        ("pbx:PortraitSimulatedAperture", "2.8"),
        ("pbx:PortraitFocusCoordinateSystem", "normalized-top-left"),
        ("mwg-rs:Regions.AppliedToDimensions.w", String(width)),
        ("mwg-rs:Regions.AppliedToDimensions.h", String(height)),
        ("mwg-rs:Regions.AppliedToDimensions.unit", "pixel"),
        ("mwg-rs:Regions.RegionList[0].Type", "Focus"),
        ("mwg-rs:Regions.RegionList[0].Area.x", "0.5"),
        ("mwg-rs:Regions.RegionList[0].Area.y", "0.5"),
        ("mwg-rs:Regions.RegionList[0].Area.w", "0.1"),
        ("mwg-rs:Regions.RegionList[0].Area.h", "0.1"),
        ("mwg-rs:Regions.RegionList[0].Area.unit", "normalized"),
        ("pbx:CaptureUUID", "11111111-2222-3333-4444-555555555555"),
        ("pbx:Provenance0", "fixture=retained|hostObserved"),
      ]
      for (path, expected) in values {
        check(portraitMetadataValue(metadata, path) == expected, "readable property \(path)")
      }
      let text = String(decoding: packet, as: UTF8.self)
      for absent in ["Calibration", "Quality=", "Filtered=", "REND", "MakerNote", "Person", "Pet"] {
        check(!text.contains(absent), "no invented \(absent) declaration")
      }
    }
  }

  await test("absentIntentAddsNoPortraitDeclarations") {
    let text = String(decoding: portraitMetadataPacket(), as: UTF8.self)
    check(!text.contains("Portrait"), "legacy and disabled packets have no profile metadata")
    check(!text.contains("mwg-rs"), "no default region added without a request")
    check(text.contains("CaptureUUID="), "ordinary capture provenance remains present")
  }
}
