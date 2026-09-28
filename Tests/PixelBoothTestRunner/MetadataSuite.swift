// Metadata tests: versioned XMP namespace, provenance separation, and the
// location acceptance policy (invalid/stale/zero/altitude rejection).

import Foundation
import PixelBoothCore
import PixelBoothMetadata
import PixelBoothAVIF

func runMetadataSuite() {
  suite("Metadata")

  test("xmpNamespaceBuildsWithProvenance") {
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      appVersion: "0.1.0",
      captureBackend: "AVFoundation",
      backendVersion: "macOS 27.0",
      libavifVersion: LosslessAVIF.libraryVersion,
      actualCaptureFormat: "NV12 8-bit 4:2:0 limited",
      encoderSettings: "codec=aom quality=lossless speed=0",
      metadataProvenance: [
        MetadataObservation(key: "exposure", rawValueString: "1/60", provenance: .cameraProvided),
        MetadataObservation(key: "gain", rawValueString: "4", provenance: .hostObserved,
                            observedAtISO: "2026-09-21T12:00:00.000Z"),
      ],
      fidelity: "nativePreserved",
      hostLocation: nil,
      mediaTimeNanos: 12345,
      wallClockAnchorISO: "2026-09-21T12:00:00.000Z")
    let text = String(bytes: xmp, encoding: .utf8) ?? ""
    check(text.contains("CaptureUUID=\"11111111-2222-3333-4444-555555555555\""), "UUID present")
    check(text.contains("AcquisitionFidelity=\"nativePreserved\""), "fidelity present")
    check(text.contains("cameraProvided"), "camera provenance labeled")
    check(text.contains("hostObserved"), "host provenance labeled")
    check(text.contains("SchemaVersion=\"1\""), "schema versioned")
  }

  test("hostLocationRecordedWithAccuracy") {
    let loc = HostLocationObservation(
      latitude: 47.6062, longitude: -122.3321, altitude: 40,
      horizontalAccuracy: 10, verticalAccuracy: 5,
      timestampISO: "2026-09-21T12:00:00.000Z", ageAtCaptureSeconds: 3)
    let xmp = PixelBoothXMP.build(
      captureUUID: UUID(), appVersion: "0.1.0",
      captureBackend: "AVFoundation", backendVersion: "macOS 27.0",
      libavifVersion: LosslessAVIF.libraryVersion,
      actualCaptureFormat: "NV12", encoderSettings: "x",
      metadataProvenance: [], fidelity: "nativePreserved",
      hostLocation: loc, mediaTimeNanos: 1, wallClockAnchorISO: "t")
    let text = String(bytes: xmp, encoding: .utf8) ?? ""
    check(text.contains("HostLatitude=\"47.6062\""), "latitude recorded")
    check(text.contains("HostHorizontalAccuracy=\"10.0\""), "accuracy recorded")
    check(text.contains("HostLocationAgeAtCaptureSeconds=\"3.0\""), "age recorded")
  }

  test("locationAcceptancePolicy") {
    let policy = LocationAcceptance(maximumAgeSeconds: 60)
    func obs(lat: Double, lon: Double, alt: Double?, age: Double) -> HostLocationObservation {
      HostLocationObservation(latitude: lat, longitude: lon, altitude: alt,
                              horizontalAccuracy: 10, verticalAccuracy: nil,
                              timestampISO: "2026-09-21T12:00:00.000Z",
                              ageAtCaptureSeconds: age)
    }
    let captureISO = "2026-09-21T12:00:00.000Z"
    check(LocationAcceptance.accept(obs(lat: 47.6, lon: -122.3, alt: 40, age: 2), atCaptureISO: captureISO, policy: policy) != nil, "valid accepted")
    check(LocationAcceptance.accept(obs(lat: 0, lon: 0, alt: nil, age: 1), atCaptureISO: captureISO, policy: policy) == nil, "zero coords rejected")
    check(LocationAcceptance.accept(obs(lat: 47.6, lon: -122.3, alt: nil, age: 61), atCaptureISO: captureISO, policy: policy) == nil, "stale rejected")
    check(LocationAcceptance.accept(obs(lat: 47.6, lon: -122.3, alt: -20000, age: 1), atCaptureISO: captureISO, policy: policy) == nil, "invalid altitude rejected")
    check(LocationAcceptance.accept(obs(lat: 95, lon: -200, alt: nil, age: 1), atCaptureISO: captureISO, policy: policy) == nil, "out-of-range rejected")
    check(LocationAcceptance.accept(nil, atCaptureISO: captureISO, policy: policy) == nil, "missing observation omitted")
  }
}
