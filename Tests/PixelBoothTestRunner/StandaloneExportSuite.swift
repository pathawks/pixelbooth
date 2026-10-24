import Darwin
import Foundation
import PixelBoothCAvifShim
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothLibrary
import PixelBoothMetadata

private enum StandaloneExportAssertion: Error { case failed(String) }

private func requireStandalone(_ condition: Bool, _ message: String) throws {
  guard condition else { throw StandaloneExportAssertion.failed(message) }
}

private func standaloneJPEG() -> CapturedCapture {
  CapturedCapture.makeTestCapture(
    fourCC: PixelFormatFourCC.mjpeg, width: 16, height: 16, payload: .jpegBytes(jpegFixture()))
}

private func withStandaloneDirectory(_ body: (URL) async throws -> Void) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pb-standalone-export-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try await body(root)
}

private func standaloneJournal(_ prepared: PreparedCaptureExport) throws -> [String: Any] {
  let data = try Data(contentsOf: prepared.recoveryDirectory.appendingPathComponent("journal.json"))
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func runStandaloneExportSuite() async {
  suite("StandaloneExport")

  await test("jpegCodingIsPreservedAndImmutableSourceIsStaged") {
    try await withStandaloneDirectory { root in
      let exporter = StandaloneCaptureExporter(stagingRoot: root)
      let capture = standaloneJPEG()
      let prepared = try await exporter.prepare(capture)
      let before = try JPEGParser.parse(jpegFixture())
      let after = try JPEGParser.parse([UInt8](Data(contentsOf: prepared.finalizedURL)))
      let codingMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC4, 0xCC, 0xDB, 0xDD]
      let beforeCoding = before.segments.filter { codingMarkers.contains($0.marker) }
      let afterCoding = after.segments.filter { codingMarkers.contains($0.marker) }
      try requireStandalone(
        before.scanAndEOI == after.scanAndEOI
          && beforeCoding.map(\.marker) == afterCoding.map(\.marker)
          && beforeCoding.map(\.payload) == afterCoding.map(\.payload),
        "JPEG coding markers and scan bytes remain exact")
      let staged = try JSONDecoder().decode(
        CapturedCapture.self,
        from: Data(contentsOf: prepared.recoveryDirectory.appendingPathComponent("capture.json")))
      try requireStandalone(staged.uuid == capture.uuid, "immutable source identity is retained")
      if case .jpegBytes(let bytes) = staged.payload {
        try requireStandalone(bytes == jpegFixture(), "staged source bytes remain exact")
      } else {
        throw StandaloneExportAssertion.failed("source payload changed representation")
      }
      let journal = try standaloneJournal(prepared)
      try requireStandalone(journal["version"] as? Int == 1, "journal is versioned")
      try requireStandalone(journal["stage"] as? String == "validated", "image is validated")
      try requireStandalone(prepared.fileExtension == "jpg", "JPEG filename matches its format")
    }
  }

  await test("avifExportRetainsExactNativePlanes") {
    try await withStandaloneDirectory { root in
      let snapshot = syntheticNV12Snapshot(width: 4, height: 2)
      var capture = CapturedCapture.makeTestCapture(
        fourCC: PixelFormatFourCC.nv12, width: 4, height: 2, payload: .planes(snapshot))
      capture.color = CapturedCapture.ColorDescriptor(
        yuvRange: .full, primaries: nil, transfer: nil, matrix: nil,
        chromaLocation: nil, iccProfile: nil)
      capture.metadata.includeEstimatedDisparity = false
      let exporter = StandaloneCaptureExporter(stagingRoot: root)
      let prepared = try await exporter.prepare(capture)
      let data = [UInt8](try Data(contentsOf: prepared.finalizedURL))
      guard let image = avifImageCreateEmpty(), let decoder = avifDecoderCreate() else {
        throw StandaloneExportAssertion.failed("decoder allocation failed")
      }
      defer {
        avifImageDestroy(image)
        avifDecoderDestroy(decoder)
      }
      let status = data.withUnsafeBufferPointer {
        avifDecoderReadMemory(decoder, image, $0.baseAddress, $0.count)
      }
      try requireStandalone(status == AVIF_RESULT_OK, "finalized AVIF decodes")
      let planes = [
        image.pointee.yuvPlanes.0, image.pointee.yuvPlanes.1, image.pointee.yuvPlanes.2,
      ]
      let strides = [
        image.pointee.yuvRowBytes.0, image.pointee.yuvRowBytes.1, image.pointee.yuvRowBytes.2,
      ]
      for planeIndex in 0..<3 {
        guard let base = planes[planeIndex] else {
          throw StandaloneExportAssertion.failed("decoded plane is absent")
        }
        var copied: [UInt8] = []
        for row in 0..<snapshot.rows[planeIndex] {
          copied.append(
            contentsOf: UnsafeBufferPointer(
              start: base.advanced(by: row * Int(strides[planeIndex])),
              count: snapshot.bytesPerRow[planeIndex]))
        }
        try requireStandalone(copied == snapshot.contiguous[planeIndex], "native samples are exact")
      }
      try requireStandalone(prepared.fileExtension == "avif", "AVIF filename matches its format")
    }
  }

  await test("existingDestinationIsUntouchedAndSourceRetained") {
    try await withStandaloneDirectory { root in
      let exporter = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
      let prepared = try await exporter.prepare(standaloneJPEG())
      let destination = root.appendingPathComponent("existing.jpg")
      let original = Data("existing photograph".utf8)
      try original.write(to: destination)
      do {
        _ = try await exporter.publish(prepared, to: destination)
        throw StandaloneExportAssertion.failed("existing output was overwritten")
      } catch is POSIXError {
        // RENAME_EXCL must refuse an existing destination.
      }
      try requireStandalone(try Data(contentsOf: destination) == original, "existing file is exact")
      try requireStandalone(
        FileManager.default.fileExists(atPath: prepared.finalizedURL.path),
        "final image is retained")
      try requireStandalone(
        try standaloneJournal(prepared)["stage"] as? String == "failed", "failure is journaled")
    }
  }

  await test("incompatibleFilenameExtensionRetainsSource") {
    try await withStandaloneDirectory { root in
      let exporter = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
      let prepared = try await exporter.prepare(standaloneJPEG())
      do {
        _ = try await exporter.publish(prepared, to: root.appendingPathComponent("wrong.avif"))
        throw StandaloneExportAssertion.failed("JPEG accepted an AVIF extension")
      } catch StandaloneCaptureExporter.ExportError.extensionMismatch(let expected) {
        try requireStandalone(expected == "jpg", "error reports actual output representation")
      }
      try requireStandalone(
        FileManager.default.fileExists(atPath: prepared.finalizedURL.path),
        "retained original exists")
    }
  }

  await test("fileAndStdoutCompletionAreIsolatedBetweenInvocations") {
    try await withStandaloneDirectory { root in
      let staging = root.appendingPathComponent("staging")
      let first = StandaloneCaptureExporter(stagingRoot: staging)
      let second = StandaloneCaptureExporter(stagingRoot: staging)
      let preparedFirst = try await first.prepare(standaloneJPEG())
      let preparedSecond = try await second.prepare(standaloneJPEG())
      let exact = try Data(contentsOf: preparedFirst.finalizedURL)
      let destination = root.appendingPathComponent("finished.jpeg")
      _ = try await first.publish(preparedFirst, to: destination)
      try requireStandalone(try Data(contentsOf: destination) == exact, "published bytes are exact")
      try requireStandalone(
        !FileManager.default.fileExists(atPath: preparedFirst.recoveryDirectory.path),
        "successful ordinary file staging is cleaned")
      try requireStandalone(
        FileManager.default.fileExists(atPath: preparedSecond.finalizedURL.path),
        "another invocation's staged source survives")
      try await second.completeStandardOutput(preparedSecond)
      try requireStandalone(
        !FileManager.default.fileExists(atPath: preparedSecond.recoveryDirectory.path),
        "successful stdout staging is cleaned")
    }
  }

  await test("encodingFailureRetainsSourceMetadataAndJournal") {
    try await withStandaloneDirectory { root in
      let exporter = StandaloneCaptureExporter(stagingRoot: root)
      var capture = CapturedCapture.makeTestCapture(
        fourCC: PixelFormatFourCC.nv12, width: 4, height: 2,
        payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
      capture.metadata.colorEncodingFailure = "Synthetic unrepresentable color metadata"
      do {
        _ = try await exporter.prepare(capture)
        throw StandaloneExportAssertion.failed("unsupported color interpretation was guessed")
      } catch CapturedCapture.SnapshotError.unsupportedColorDescriptor {
        // Expected: source retention precedes finalization.
      }
      guard let directory = await exporter.recoveryDirectory else {
        throw StandaloneExportAssertion.failed("failure has no recovery directory")
      }
      for file in ["capture.json", "metadata-report.json", "journal.json"] {
        try requireStandalone(
          FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path),
          "recoverable \(file) is retained")
      }
    }
  }

  await test("metadataWarningsRetainEvidenceAfterSuccessfulOutput") {
    try await withStandaloneDirectory { root in
      let exporter = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
      var capture = standaloneJPEG()
      capture.metadata.attachmentArchive = CaptureAttachmentArchive(
        issues: ["Synthetic unmapped metadata retained for review"])
      let prepared = try await exporter.prepare(capture)
      _ = try await exporter.publish(prepared, to: root.appendingPathComponent("warning.jpg"))
      try requireStandalone(
        FileManager.default.fileExists(atPath: prepared.recoveryDirectory.path),
        "diagnostic evidence survives successful output")
      try requireStandalone(
        try standaloneJournal(prepared)["stage"] as? String == "savedWithMetadataReport",
        "successful warning state is explicit")
    }
  }

  await test("capacityIncludesReservationsFromOtherInvocations") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root, maximumStagedBytes: 12 * 1024 * 1024)
      let second = StandaloneCaptureExporter(
        stagingRoot: root, maximumStagedBytes: 12 * 1024 * 1024)
      _ = try await first.prepare(standaloneJPEG())
      let refused = standaloneJPEG()
      do {
        _ = try await second.prepare(refused)
        throw StandaloneExportAssertion.failed("capacity promised to another invocation was reused")
      } catch SaveQueueActor.QueueError.capacityExceeded {
        // Reservation includes source, finalized output and atomic temporary files.
      }
      try requireStandalone(
        !FileManager.default.fileExists(
          atPath: root.appendingPathComponent(refused.uuid.uuidString).path),
        "refusal leaves no orphan source directory")
    }
  }

  await test("recoveryReusesTheVerifiedFinalizedFile") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      let exact = try Data(contentsOf: original.finalizedURL)
      try await first.recordFailure(original, message: "Synthetic destination failure")
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      let resumed = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
      try requireStandalone(
        resumed.captureUUID == original.captureUUID, "recovery preserves identity")
      try requireStandalone(
        try Data(contentsOf: resumed.finalizedURL) == exact, "recovery reuses exact verified bytes")
      try await retry.completeStandardOutput(resumed)
    }
  }

  await test("recoveryRefinalizesAMissingImageFromItsExactSource") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      let exact = try Data(contentsOf: original.finalizedURL)
      try await first.recordFailure(original, message: "Synthetic interrupted save")
      try FileManager.default.removeItem(at: original.finalizedURL)
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      let resumed = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
      try requireStandalone(
        try Data(contentsOf: resumed.finalizedURL) == exact,
        "retained source reproduces the finalized JPEG")
      try await retry.completeStandardOutput(resumed)
    }
  }

  await test("activeInvocationCannotBeRecoveredConcurrently") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      do {
        _ = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        throw StandaloneExportAssertion.failed("concurrent recovery acquired an active capture")
      } catch StandaloneCaptureExporter.ExportError.busy {
        // Independent file descriptors contend even in the same process.
      }
      try requireStandalone(
        FileManager.default.fileExists(atPath: original.finalizedURL.path),
        "active output remains intact")
      try await first.completeStandardOutput(original)
    }
  }

  await test("corruptSourceRefusesRecoveryWithoutChangingEvidence") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      try await first.recordFailure(original, message: "Synthetic destination failure")
      let sourceURL = original.recoveryDirectory.appendingPathComponent("capture.json")
      let corrupt = Data("corrupt source evidence".utf8)
      try corrupt.write(to: sourceURL)
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      do {
        _ = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        throw StandaloneExportAssertion.failed("corrupt source was accepted")
      } catch StandaloneCaptureExporter.ExportError.storage(let message) {
        try requireStandalone(message.contains("integrity"), "source hash failure is explained")
      }
      try requireStandalone(
        try Data(contentsOf: sourceURL) == corrupt, "source evidence is unchanged")
    }
  }

  await test("corruptFinalImageRefusesRecoveryWithoutReplacingEvidence") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      try await first.recordFailure(original, message: "Synthetic destination failure")
      let corrupt = Data("corrupt finalized evidence".utf8)
      try corrupt.write(to: original.finalizedURL)
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      do {
        _ = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        throw StandaloneExportAssertion.failed("corrupt final image was accepted")
      } catch StandaloneCaptureExporter.ExportError.storage(let message) {
        try requireStandalone(
          message.contains("integrity"), "final image hash failure is explained")
      }
      try requireStandalone(
        try Data(contentsOf: original.finalizedURL) == corrupt,
        "corrupt finalized evidence is unchanged")
    }
  }

  await test("recoveryCannotReadSourceThroughASymbolicLink") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
      let original = try await first.prepare(standaloneJPEG())
      try await first.recordFailure(original, message: "Synthetic destination failure")
      let sourceURL = original.recoveryDirectory.appendingPathComponent("capture.json")
      let outside = root.appendingPathComponent("external-source.json")
      try FileManager.default.moveItem(at: sourceURL, to: outside)
      try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outside)
      let retry = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
      do {
        _ = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        throw StandaloneExportAssertion.failed("recovery followed a source symlink")
      } catch is POSIXError {
        // O_NOFOLLOW rejects the substituted source file.
      }
      try requireStandalone(
        FileManager.default.fileExists(atPath: outside.path), "external evidence is untouched")
    }
  }

  await test("recoveryRefusesANonregularSourceWithoutBlocking") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      let original = try await first.prepare(standaloneJPEG())
      try await first.recordFailure(original, message: "Synthetic destination failure")
      let sourceURL = original.recoveryDirectory.appendingPathComponent("capture.json")
      try FileManager.default.removeItem(at: sourceURL)
      guard Darwin.mkfifo(sourceURL.path, 0o600) == 0 else {
        throw StandaloneExportAssertion.failed("cannot create synthetic FIFO")
      }
      let retry = StandaloneCaptureExporter(stagingRoot: root)
      do {
        _ = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        throw StandaloneExportAssertion.failed("recovery accepted a FIFO source")
      } catch StandaloneCaptureExporter.ExportError.storage(let message) {
        try requireStandalone(message.contains("regular"), "nonregular source is explained")
      }
    }
  }

  await test("capacityAdmissionRefusesAContendedLockWithoutBlocking") {
    try await withStandaloneDirectory { root in
      let first = StandaloneCaptureExporter(stagingRoot: root)
      _ = try await first.prepare(standaloneJPEG())
      let descriptor = Darwin.open(root.appendingPathComponent(".capacity.lock").path, O_RDWR)
      guard descriptor >= 0 else {
        throw StandaloneExportAssertion.failed("capacity lock is absent")
      }
      defer { Darwin.close(descriptor) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw StandaloneExportAssertion.failed("cannot hold synthetic capacity lock")
      }
      let next = StandaloneCaptureExporter(stagingRoot: root)
      do {
        _ = try await next.prepare(standaloneJPEG())
        throw StandaloneExportAssertion.failed("admission ignored a contended capacity lock")
      } catch StandaloneCaptureExporter.ExportError.busy {
        // Admission is bounded even if another CLI process is suspended.
      }
    }
  }

  await test("recoveryHandlesBothSidesOfFinalImagePublication") {
    for outputWasPublished in [false, true] {
      try await withStandaloneDirectory { root in
        let first = StandaloneCaptureExporter(stagingRoot: root)
        let original = try await first.prepare(standaloneJPEG())
        let exact = try Data(contentsOf: original.finalizedURL)
        try await first.recordFailure(original, message: "Synthetic process interruption")
        let journalURL = original.recoveryDirectory.appendingPathComponent("journal.json")
        var interrupted = try standaloneJournal(original)
        interrupted["stage"] = "validating"
        try JSONSerialization.data(withJSONObject: interrupted).write(to: journalURL)
        if !outputWasPublished { try FileManager.default.removeItem(at: original.finalizedURL) }
        let retry = StandaloneCaptureExporter(stagingRoot: root)
        let resumed = try await retry.resume(recoveryDirectory: original.recoveryDirectory)
        try requireStandalone(
          try Data(contentsOf: resumed.finalizedURL) == exact,
          "interrupted publication recovers the exact finalized image")
        try requireStandalone(
          try standaloneJournal(resumed)["stage"] as? String == "validated",
          "interrupted publication returns to a validated state")
        try await retry.completeStandardOutput(resumed)
      }
    }
  }

  await test("fileDestinationsCannotAliasRecoveryStaging") {
    try await withStandaloneDirectory { root in
      let staging = root.appendingPathComponent("staging", isDirectory: true)
      let exporter = StandaloneCaptureExporter(stagingRoot: staging)
      let prepared = try await exporter.prepare(standaloneJPEG())
      let alias = root.appendingPathComponent("staging-alias", isDirectory: true)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: staging)
      let destinations = [
        prepared.recoveryDirectory.appendingPathComponent("published.jpg"),
        staging.appendingPathComponent("published.jpg"),
        alias.appendingPathComponent("published.jpg"),
        alias.appendingPathComponent("absent-parent/published.jpg"),
        staging.resolvingSymlinksInPath()
          .appendingPathComponent("filesystem-alias.jpg"),
        staging,
      ]
      for destination in destinations {
        do {
          _ = try await exporter.publish(prepared, to: destination)
          throw StandaloneExportAssertion.failed(
            "an output destination aliased recovery staging: \(destination.path)")
        } catch StandaloneCaptureExporter.ExportError.storage(let message) {
          try requireStandalone(message.contains("outside"), "recovery containment is explained")
        }
        try requireStandalone(
          FileManager.default.fileExists(atPath: prepared.finalizedURL.path),
          "rejected staging destinations retain the finalized image")
        try requireStandalone(
          FileManager.default.fileExists(
            atPath: prepared.recoveryDirectory.appendingPathComponent("capture.json").path),
          "rejected staging destinations retain the source")
      }
    }
  }

  await test("caseInsensitiveAliasesCannotReceiveFilesInRecoveryStaging") {
    try await withStandaloneDirectory { root in
      let staging = root.appendingPathComponent("staging", isDirectory: true)
      let exporter = StandaloneCaptureExporter(stagingRoot: staging)
      let prepared = try await exporter.prepare(standaloneJPEG())
      let alias = root.appendingPathComponent("STAGING", isDirectory: true)
      guard FileManager.default.fileExists(atPath: alias.path) else {
        try skipTest("temporary filesystem is case-sensitive")
      }
      let destination = alias.appendingPathComponent("case-alias.jpg")
      do {
        _ = try await exporter.publish(prepared, to: destination)
        throw StandaloneExportAssertion.failed(
          "case-insensitive output aliased recovery staging: \(destination.path)")
      } catch StandaloneCaptureExporter.ExportError.storage(let message) {
        try requireStandalone(
          message.contains("outside"), "filesystem identity containment is explained")
      }
      try requireStandalone(
        FileManager.default.fileExists(atPath: prepared.finalizedURL.path),
        "case-insensitive destination refusal retains finalized evidence")
    }
  }
}
