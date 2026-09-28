import Foundation
import PixelBoothAVIF
import PixelBoothJPEG
import PixelBoothLibrary

private enum RecoveryAssertion: Error { case failed(String) }

private actor ImportSequence {
  private var results: [SaveQueueActor.ImportResult]
  private(set) var calls = 0
  private(set) var sawDurableSourceAndJournal = true
  private let root: URL
  private let captureID: UUID

  init(results: [SaveQueueActor.ImportResult], root: URL, captureID: UUID) {
    self.results = results
    self.root = root
    self.captureID = captureID
  }

  func run(_ file: URL) -> SaveQueueActor.ImportResult {
    calls += 1
    let source = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(captureID.uuidString, isDirectory: true)
      .appendingPathComponent("capture.json")
    let journal = root.appendingPathComponent("journal.json")
    sawDurableSourceAndJournal =
      sawDurableSourceAndJournal && FileManager.default.fileExists(atPath: source.path)
      && FileManager.default.fileExists(atPath: journal.path)
      && FileManager.default.fileExists(atPath: file.path)
    return results.isEmpty ? .saved : results.removeFirst()
  }
}

private actor ImportGate {
  private var continuation: CheckedContinuation<SaveQueueActor.ImportResult, Never>?

  func run() async -> SaveQueueActor.ImportResult {
    await withCheckedContinuation { continuation = $0 }
  }

  func finish(_ result: SaveQueueActor.ImportResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

private actor TerminationWaitSignal {
  private(set) var completed = false

  func markCompleted() {
    completed = true
  }
}

private actor PhotosAuthorizationProbe {
  private let initial: SaveQueueActor.PhotosAuthorizationState
  private let requested: SaveQueueActor.PhotosAuthorizationState
  private(set) var requestCount = 0

  init(
    initial: SaveQueueActor.PhotosAuthorizationState,
    requested: SaveQueueActor.PhotosAuthorizationState
  ) {
    self.initial = initial
    self.requested = requested
  }

  func state(requestPermission: Bool) -> SaveQueueActor.PhotosAuthorizationState {
    if requestPermission {
      requestCount += 1
      return requested
    }
    return initial
  }
}

private func waitForStage(_ queue: SaveQueueActor, id: UUID, _ stages: Set<SaveQueueActor.Stage>)
  async throws -> SaveQueueActor.JournalEntry
{
  for _ in 0..<100 {
    if let entry = try await queue.entries().first(where: { $0.uuid == id }),
      stages.contains(entry.stage)
    {
      return entry
    }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  throw RecoveryAssertion.failed("timed out waiting for (id)")
}

private func fixtureCapture() -> CapturedCapture {
  CapturedCapture.makeTestCapture(
    fourCC: 0x4d4a_5047, width: 4, height: 4,
    payload: .jpegBytes(jpegFixture()))
}

private func fixtureCaptureWithStaleDimensions() -> CapturedCapture {
  var capture = CapturedCapture.makeTestCapture(
    fourCC: 0x4e56_3132, width: 8, height: 6,
    payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
  capture.color = CapturedCapture.ColorDescriptor(
    yuvRange: .full, primaries: nil, transfer: nil, matrix: nil,
    chromaLocation: nil, iccProfile: nil)
  return capture
}

func runRecoverySuite() async {
  suite("DurableSaveRecovery")

  await test("stagingFailureRefusesEnqueueAndDoesNotInvokeImporter") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-block-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = root.appendingPathComponent("not-a-directory")
    try Data([1]).write(to: blocker)
    let capture = fixtureCapture()
    let importer = ImportSequence(results: [.saved], root: root, captureID: capture.uuid)
    let queue = SaveQueueActor(
      stagingRoot: blocker.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) })
    do {
      try await queue.enqueue(capture)
      throw RecoveryAssertion.failed("failed staging was accepted")
    } catch is SaveQueueActor.QueueError {}
    try requireRecovery(
      await importer.calls == 0, "Photo importer not called after staging failure")
  }

  await test("notDeterminedPhotosAccessRequestsAuthorizationBeforeImport") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-photos-request-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(results: [.saved], root: root, captureID: capture.uuid)
    let authorization = PhotosAuthorizationProbe(initial: .notDetermined, requested: .authorized)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) },
      photosAuthorizationProvider: { request in
        await authorization.state(requestPermission: request)
      })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.saved])
    try requireRecovery(await authorization.requestCount == 1, "first save requested permission")
    try requireRecovery(await importer.calls == 1, "authorized capture reached the importer")
  }

  await test("deniedPhotosAccessIsActionableAndDoesNotCallImporter") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-photos-denied-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(results: [.saved], root: root, captureID: capture.uuid)
    let authorization = PhotosAuthorizationProbe(initial: .denied, requested: .authorized)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) },
      photosAuthorizationProvider: { request in
        await authorization.state(requestPermission: request)
      })
    try await queue.enqueue(capture)
    let failed = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try requireRecovery(
      failed.lastError?.contains("System Settings") == true,
      "denied access explains how to restore permission")
    try requireRecovery(await authorization.requestCount == 0, "denial does not prompt repeatedly")
    try requireRecovery(await importer.calls == 0, "denied capture does not reach Photos import")
    try requireRecovery(
      SaveQueueActor.PhotosAuthorizationState.restricted.recoveryMessage?.contains("restricted")
        == true,
      "restricted access has a distinct explanation")
  }

  await test("durableFailureExportsExactOriginalAsCompletedAction") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.failed("Photos denied")], root: root, captureID: capture.uuid)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    let failed = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try requireRecovery(
      await importer.sawDurableSourceAndJournal,
      "source, journal, and final file existed before import")
    try requireRecovery(
      failed.codecFileName == "capture.jpg" && failed.fileHashSHA256 != nil,
      "verified file recorded")
    let stagedSource = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(capture.uuid.uuidString, isDirectory: true).appendingPathComponent(
        "capture.json")
    try requireRecovery(
      FileManager.default.fileExists(atPath: stagedSource.path), "failed capture source retained")
    let expectedFile = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(capture.uuid.uuidString, isDirectory: true).appendingPathComponent(
        "capture.jpg")
    let expectedBytes = try Data(contentsOf: expectedFile)
    let exported = root.appendingPathComponent("exported-original.jpg")
    _ = try await queue.saveOriginal(uuid: capture.uuid, to: exported)
    try requireRecovery(
      try Data(contentsOf: exported) == expectedBytes,
      "export is byte-identical to finalized original")
    _ = try await waitForStage(queue, id: capture.uuid, [.exportedOriginal])
    try requireRecovery(
      await importer.calls == 1, "explicit export does not unexpectedly retry Photos")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: stagedSource.path),
      "durable export completion cleans staging")
    do {
      try await queue.retry(uuid: capture.uuid)
      throw RecoveryAssertion.failed("exported original was rescheduled to Photos")
    } catch SaveQueueActor.QueueError.originalUnavailable(_) {}
  }

  await test("staleLegacyPlaneDimensionsCanRetryAndExport") {
    let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-stale-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: exportRoot) }
    let exportCapture = fixtureCaptureWithStaleDimensions()
    let exportImporter = ImportSequence(
      results: [.failed("Photos unavailable")], root: exportRoot,
      captureID: exportCapture.uuid)
    let exportQueue = SaveQueueActor(
      stagingRoot: exportRoot.appendingPathComponent("staging"),
      importer: { file, _ in await exportImporter.run(file) })
    try await exportQueue.enqueue(exportCapture)
    _ = try await waitForStage(exportQueue, id: exportCapture.uuid, [.failedAddingToPhotos])
    let exportedURL = exportRoot.appendingPathComponent("saved-original.avif")
    _ = try await exportQueue.saveOriginal(uuid: exportCapture.uuid, to: exportedURL)
    let exportedImage = try LosslessAVIF.decode(encoded: [UInt8](Data(contentsOf: exportedURL)))
    try requireRecovery(
      exportedImage.width == 4 && exportedImage.height == 2,
      "legacy stale dimensions can export the exact image geometry")

    let retryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-stale-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: retryRoot) }
    let retryCapture = fixtureCaptureWithStaleDimensions()
    let retryImporter = ImportSequence(
      results: [.failed("Photos unavailable"), .saved], root: retryRoot,
      captureID: retryCapture.uuid)
    let retryQueue = SaveQueueActor(
      stagingRoot: retryRoot.appendingPathComponent("staging"),
      importer: { file, _ in await retryImporter.run(file) })
    try await retryQueue.enqueue(retryCapture)
    _ = try await waitForStage(retryQueue, id: retryCapture.uuid, [.failedAddingToPhotos])
    try await retryQueue.retry(uuid: retryCapture.uuid)
    _ = try await waitForStage(retryQueue, id: retryCapture.uuid, [.saved])
    try requireRecovery(await retryImporter.calls == 2, "retry reuses corrected plane geometry")
  }

  await test("unsupportedColorFailureCanBeDismissedWithoutDeletingSource") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-dismiss-unsupported-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = CapturedCapture.makeTestCapture(
      fourCC: 0x4e56_3132, width: 4, height: 2,
      payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
    let queue = SaveQueueActor(stagingRoot: root.appendingPathComponent("staging"))
    try await queue.enqueue(capture)
    let entry = try await waitForStage(
      queue, id: capture.uuid, [.failedUnsupportedColorDescriptor])
    let source = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.json")
    try requireRecovery(FileManager.default.fileExists(atPath: source.path), "source retained")

    do {
      try await queue.retry(uuid: capture.uuid)
      throw RecoveryAssertion.failed("known permanent color-metadata failure was retryable")
    } catch SaveQueueActor.QueueError.originalUnavailable(_) {}

    try await queue.dismissUnsupportedCaptureFromProgress(uuid: capture.uuid)
    let dismissed = try await queue.entries().first(where: { $0.uuid == capture.uuid })
    try requireRecovery(
      dismissed?.stage == .failedUnsupportedColorDescriptor
        && dismissed?.isProgressDismissed == true,
      "dismissal hides progress but leaves the failed journal entry")
    try requireRecovery(
      FileManager.default.fileExists(atPath: source.path), "source remains recoverable")

    try await queue.dismissRetainedCapture(uuid: capture.uuid)
    let hidden = try await queue.entries().first(where: { $0.uuid == capture.uuid })
    try requireRecovery(hidden?.isRetainedDismissed == true, "retained capture can be hidden")
    try requireRecovery(
      FileManager.default.fileExists(atPath: source.path), "dismissal preserves retained source")
    try await queue.restoreRetainedCapture(uuid: capture.uuid)
    let restored = try await queue.entries().first(where: { $0.uuid == capture.uuid })
    try requireRecovery(restored?.isRetainedDismissed == false, "retained capture can be restored")
    try requireRecovery(
      FileManager.default.fileExists(atPath: source.path), "restored capture remains recoverable")

    let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-dismiss-legacy-unsupported-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: legacyRoot) }
    let legacyCapture = CapturedCapture.makeTestCapture(
      fourCC: 0x4e56_3132, width: 4, height: 2,
      payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
    let legacyQueue = SaveQueueActor(stagingRoot: legacyRoot.appendingPathComponent("staging"))
    try await legacyQueue.enqueue(legacyCapture)
    _ = try await waitForStage(
      legacyQueue, id: legacyCapture.uuid, [.failedUnsupportedColorDescriptor])
    let journalURL = legacyRoot.appendingPathComponent("journal.json")
    let journalData = try Data(contentsOf: journalURL)
    var journal = try JSONSerialization.jsonObject(with: journalData) as! [String: Any]
    var entries = journal["entries"] as! [[String: Any]]
    guard
      let index = entries.firstIndex(where: {
        $0["uuid"] as? String == legacyCapture.uuid.uuidString
      })
    else {
      throw RecoveryAssertion.failed("legacy entry missing")
    }
    entries[index]["stage"] = SaveQueueActor.Stage.failedEncoding.rawValue
    entries[index]["lastError"] = "SnapshotError 1"
    journal["entries"] = entries
    try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

    try await legacyQueue.reconcileOnLaunch()
    let legacyEntry = try await legacyQueue.entries().first(where: { $0.uuid == legacyCapture.uuid }
    )
    try requireRecovery(
      legacyEntry?.stage == .failedUnsupportedColorDescriptor
        && legacyEntry?.isPermanentlyUnencodable == true,
      "legacy SnapshotError 1 migrates to a permanent color failure")
    try await legacyQueue.dismissUnsupportedCaptureFromProgress(uuid: legacyCapture.uuid)
    let legacyDismissed = try await legacyQueue.entries().first(where: {
      $0.uuid == legacyCapture.uuid
    })
    try requireRecovery(
      legacyDismissed?.stage == .failedUnsupportedColorDescriptor
        && legacyDismissed?.isProgressDismissed == true,
      "legacy failure migrates when dismissed")
  }

  await test("saveAsRunsWhilePhotosImportIsPending") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-save-as-worker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let gate = ImportGate()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in await gate.run() })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.addingToPhotos])

    let finalized = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
      .appendingPathComponent("capture.jpg")
    let expected = try Data(contentsOf: finalized)
    let destination = root.appendingPathComponent("save-as.jpg")
    _ = try await queue.saveOriginal(uuid: capture.uuid, to: destination)
    try requireRecovery(
      try Data(contentsOf: destination) == expected,
      "Save As copies the finalized file without waiting for Photos")
    _ = try await waitForStage(queue, id: capture.uuid, [.addingToPhotos])

    await gate.finish(.failed("simulated Photos failure"))
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
  }

  await test("terminationWaitsForActiveWorkAndRejectsNewCaptures") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-termination-drain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let gate = ImportGate()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in await gate.run() })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.addingToPhotos])

    try requireRecovery(await queue.beginTermination(), "active save prevents immediate quit")
    do {
      try await queue.enqueue(fixtureCapture())
      throw RecoveryAssertion.failed("queue accepted a capture after termination started")
    } catch SaveQueueActor.QueueError.terminating {}

    let signal = TerminationWaitSignal()
    let waitTask = Task {
      await queue.waitForTerminationWorkToFinish()
      await signal.markCompleted()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    try requireRecovery(!(await signal.completed), "termination waits for the active Photos save")

    await gate.finish(.saved)
    await waitTask.value
    try requireRecovery(await signal.completed, "termination resumes after active work finishes")
    _ = try await waitForStage(queue, id: capture.uuid, [.saved])
  }

  await test("ambiguousImportNeedsExplicitDuplicateConfirmation") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-ambig-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.uncertain("simulated lost completion"), .saved], root: root,
      captureID: capture.uuid)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.ambiguousImport])
    do {
      try await queue.retry(uuid: capture.uuid)
      throw RecoveryAssertion.failed("ambiguous retry did not require confirmation")
    } catch SaveQueueActor.QueueError.ambiguousNeedsConfirmation {}
    try await queue.retry(uuid: capture.uuid, confirmingPossibleDuplicate: true)
    _ = try await waitForStage(queue, id: capture.uuid, [.saved])
    try requireRecovery(await importer.calls == 2, "confirmed replay reached importer once")
  }

  await test("corruptJournalIsNeverOverwritten") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-corrupt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let journal = root.appendingPathComponent("journal.json")
    let corrupt = Data("{bad journal".utf8)
    try corrupt.write(to: journal)
    let queue = SaveQueueActor(stagingRoot: root.appendingPathComponent("staging"))
    do {
      try await queue.reconcileOnLaunch()
      throw RecoveryAssertion.failed("corrupt journal accepted")
    } catch SaveQueueActor.QueueError.journal {}
    try requireRecovery(
      try Data(contentsOf: journal) == corrupt, "corrupt journal bytes left untouched")
  }
}
