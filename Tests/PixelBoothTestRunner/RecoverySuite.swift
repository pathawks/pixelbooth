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

private actor FirstFailureThenImportGate {
  private var calls = 0
  private let gate: ImportGate

  init(gate: ImportGate) { self.gate = gate }

  func run() async -> SaveQueueActor.ImportResult {
    calls += 1
    if calls == 1 { return .failed("simulated Photos failure") }
    return await gate.run()
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

private func waitForDeletionReady(_ queue: SaveQueueActor, id: UUID) async throws -> [String] {
  for _ in 0..<100 {
    do { return try await queue.retainedFilesForDeletion(uuid: id) } catch SaveQueueActor.QueueError
      .busy
    {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
  throw RecoveryAssertion.failed("timed out waiting for retained capture processing to finish")
}

private func largeJPEGFixtureCapture() -> CapturedCapture {
  var bytes = jpegFixture()
  let payload = [UInt8](repeating: 0x41, count: 59_998)
  let segmentLength = payload.count + 2
  let segment: [UInt8] =
    [
      0xff, 0xe1, UInt8((segmentLength >> 8) & 0xff), UInt8(segmentLength & 0xff),
    ] + payload
  for _ in 0..<70 {
    bytes.insert(contentsOf: segment, at: 2)
  }
  return CapturedCapture.makeTestCapture(
    fourCC: 0x4d4a_5047, width: 4, height: 4, payload: .jpegBytes(bytes))
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

  await test("confirmedRetainedDeleteIsSymlinkSafeAndIsolated") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-delete-retained-safe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.failed("Photos unavailable")], root: root, captureID: capture.uuid)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let queue = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
    let stagedCapture = staging.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    let source = stagedCapture.appendingPathComponent("capture.json")
    let unrelated = staging.appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: unrelated)
    let symlink = stagedCapture.appendingPathComponent("unexpected-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

    do {
      _ = try await waitForDeletionReady(queue, id: capture.uuid)
      try await queue.deleteRetainedCapture(uuid: capture.uuid)
      throw RecoveryAssertion.failed("delete accepted a symbolic link in the capture directory")
    } catch SaveQueueActor.QueueError.staging {}
    try requireRecovery(FileManager.default.fileExists(atPath: source.path), "source is retained")
    try requireRecovery(
      FileManager.default.fileExists(atPath: unrelated.path), "sibling is retained")
    let stillRetained = try await queue.entries().first(where: { $0.uuid == capture.uuid })
    try requireRecovery(
      stillRetained?.shouldDiscardOnTermination == false,
      "failed path validation does not record a delete transition")

    try FileManager.default.removeItem(at: symlink)
    let interruptedTemporary = stagedCapture.appendingPathComponent(
      ".capture.jpg.\(UUID().uuidString).tmp")
    try Data([1, 2, 3]).write(to: interruptedTemporary)
    let names = try await waitForDeletionReady(queue, id: capture.uuid)
    try requireRecovery(names.contains("capture.json"), "confirmation names retained source")
    try requireRecovery(
      names.contains(interruptedTemporary.lastPathComponent),
      "confirmation includes a known interrupted atomic-write temporary")
    try await queue.deleteRetainedCapture(uuid: capture.uuid)
    try requireRecovery(
      try await queue.entries().allSatisfy({ $0.uuid != capture.uuid }),
      "confirmed delete removes only the target journal row")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: stagedCapture.path), "target removed")
    try requireRecovery(
      FileManager.default.fileExists(atPath: unrelated.path), "sibling is untouched")
  }

  await test("retainedDeleteRefusesActiveImport") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-delete-retained-busy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let gate = ImportGate()
    let importer = FirstFailureThenImportGate(gate: gate)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in await importer.run() })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
    _ = try await waitForDeletionReady(queue, id: capture.uuid)

    try await queue.retry(uuid: capture.uuid)
    _ = try await waitForStage(queue, id: capture.uuid, [.addingToPhotos])
    do {
      try await queue.deleteRetainedCapture(uuid: capture.uuid)
      throw RecoveryAssertion.failed("delete was accepted during a pending Photos import")
    } catch SaveQueueActor.QueueError.busy {}
    try requireRecovery(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("staging", isDirectory: true)
          .appendingPathComponent(capture.uuid.uuidString, isDirectory: true).path),
      "active capture files remain staged")
    await gate.finish(.failed("simulated Photos failure"))
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
  }

  await test("retainedDeleteReclaimsStagingCapacity") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-delete-capacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = largeJPEGFixtureCapture()
    var second = first
    second.uuid = UUID()
    let importer = ImportSequence(
      results: [.failed("Photos unavailable"), .failed("Photos unavailable")],
      root: root, captureID: first.uuid)
    // One large JPEG fits, but its retained source plus the conservative
    // reservation for another capture exceeds this bound.
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) },
      maximumStagedBytes: 40 * 1024 * 1024)
    try await queue.enqueue(first)
    _ = try await waitForStage(queue, id: first.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: first.uuid)
    _ = try await waitForDeletionReady(queue, id: first.uuid)
    do {
      try await queue.enqueue(second)
      throw RecoveryAssertion.failed("capture was accepted while retained staging filled capacity")
    } catch SaveQueueActor.QueueError.capacityExceeded {}

    try await queue.deleteRetainedCapture(uuid: first.uuid)
    try await queue.enqueue(second)
    _ = try await waitForStage(queue, id: second.uuid, [.failedAddingToPhotos])
    try requireRecovery(
      try await queue.entries().contains(where: { $0.uuid == second.uuid }),
      "a new capture fits after confirmed retained deletion")
  }

  await test("interruptedConfirmedDeleteFinishesOnRelaunch") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-delete-relaunch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.failed("Photos unavailable")], root: root, captureID: capture.uuid)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let queue = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
    _ = try await waitForDeletionReady(queue, id: capture.uuid)
    let sourceDirectory = staging.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)

    let journalURL = root.appendingPathComponent("journal.json")
    var journal =
      try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
    var entries = journal["entries"] as! [[String: Any]]
    entries[0]["discardOnTermination"] = true
    journal["entries"] = entries
    try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

    let relaunchedImporter = ImportSequence(
      results: [.saved], root: root, captureID: capture.uuid)
    let relaunched = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, _ in await relaunchedImporter.run(file) })
    try await relaunched.reconcileOnLaunch()
    try requireRecovery(
      try await relaunched.entries().isEmpty, "delete intent removes its journal row")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: sourceDirectory.path),
      "delete intent removes target staging on relaunch")
    try requireRecovery(await relaunchedImporter.calls == 0, "deleted capture is never imported")
  }

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

  await test("allFailedCapturesCanBeDismissedDurablyAndRetriedWithoutLosingData") {
    let failureStages: [SaveQueueActor.Stage] = [
      .failedEncoding, .failedValidating, .failedAddingToPhotos, .failedDiskFull,
      .failedUnsupportedColorDescriptor, .ambiguousImport,
    ]
    for stage in failureStages {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pb-dismiss-\(stage.rawValue)-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let capture = fixtureCapture()
      let importer = ImportSequence(
        results: [.failed("simulated failure")], root: root,
        captureID: capture.uuid)
      let staging = root.appendingPathComponent("staging")
      let queue = SaveQueueActor(
        stagingRoot: staging,
        importer: { file, _ in await importer.run(file) })
      try await queue.enqueue(capture)
      let failed = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
      let source = URL(fileURLWithPath: failed.stagingPath).appendingPathComponent("capture.json")
      let finalized = URL(fileURLWithPath: failed.stagingPath).appendingPathComponent("capture.jpg")
      let sourceBytes = try Data(contentsOf: source)
      let finalizedBytes = try Data(contentsOf: finalized)

      let journalURL = root.appendingPathComponent("journal.json")
      var journal =
        try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
        as! [String: Any]
      var entries = journal["entries"] as! [[String: Any]]
      entries[0]["stage"] = stage.rawValue
      journal["entries"] = entries
      try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

      try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
      let dismissed = try await queue.entries().first(where: { $0.uuid == capture.uuid })
      try requireRecovery(dismissed?.stage == stage, "dismissal preserves failure classification")
      try requireRecovery(
        dismissed?.isProgressDismissed == true && dismissed?.isRetainedDismissed == true,
        "dismissal hides the capture while PixelBooth remains open")
      try requireRecovery(try Data(contentsOf: source) == sourceBytes, "source bytes preserved")
      try requireRecovery(
        try Data(contentsOf: finalized) == finalizedBytes, "finalized bytes preserved")
      try requireRecovery(await importer.calls == 1, "dismissal never imports")

      if stage != .failedUnsupportedColorDescriptor {
        try await queue.retry(uuid: capture.uuid, confirmingPossibleDuplicate: true)
        let saved = try await waitForStage(queue, id: capture.uuid, [.saved])
        try requireRecovery(
          !saved.isProgressDismissed && !saved.isRetainedDismissed,
          "explicit retry restores visible save progress")
        try requireRecovery(await importer.calls == 2, "retry imports once")
      }
    }
  }

  await test("activeCaptureCannotBeDismissed") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-dismiss-active-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let gate = ImportGate()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in await gate.run() })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.addingToPhotos])
    do {
      try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
      throw RecoveryAssertion.failed("active capture was dismissed")
    } catch SaveQueueActor.QueueError.originalUnavailable(_) {}
    await gate.finish(.failed("simulated failure"))
    let failed = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try requireRecovery(!failed.isProgressDismissed, "active capture remains visible")
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
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in .failed("Synthetic importer; Photos access disabled in automated tests") }
    )
    try await queue.enqueue(capture)
    let entry = try await waitForStage(
      queue, id: capture.uuid, [.failedUnsupportedColorDescriptor])
    let source = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.json")
    try requireRecovery(FileManager.default.fileExists(atPath: source.path), "source retained")

    do {
      try await queue.retry(uuid: capture.uuid)
      throw RecoveryAssertion.failed("known permanent color-metadata failure was retryable")
    } catch SaveQueueActor.QueueError.originalUnavailable(_) {}

    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
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
    let legacyQueue = SaveQueueActor(
      stagingRoot: legacyRoot.appendingPathComponent("staging"),
      importer: { _, _ in .failed("Synthetic importer; Photos access disabled in automated tests") }
    )
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
    try await legacyQueue.dismissFailedCaptureFromProgress(uuid: legacyCapture.uuid)
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

  await test("terminationDeletesOnlyDismissedRetainedCaptures") {
    let dismissedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-termination-dismissed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dismissedRoot) }
    let dismissedCapture = fixtureCapture()
    let dismissedImporter = ImportSequence(
      results: [.failed("Photos unavailable")], root: dismissedRoot,
      captureID: dismissedCapture.uuid)
    let dismissedQueue = SaveQueueActor(
      stagingRoot: dismissedRoot.appendingPathComponent("staging"),
      importer: { file, _ in await dismissedImporter.run(file) })
    try await dismissedQueue.enqueue(dismissedCapture)
    _ = try await waitForStage(
      dismissedQueue, id: dismissedCapture.uuid, [.failedAddingToPhotos])
    try await dismissedQueue.dismissFailedCaptureFromProgress(uuid: dismissedCapture.uuid)
    let dismissedDirectory = dismissedRoot.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(dismissedCapture.uuid.uuidString, isDirectory: true)
    try requireRecovery(
      FileManager.default.fileExists(atPath: dismissedDirectory.path),
      "dismissed capture remains recoverable until the app quits")

    if await dismissedQueue.beginTermination() {
      await dismissedQueue.waitForTerminationWorkToFinish()
    }
    let removedCount = try await dismissedQueue.discardDismissedCapturesOnTermination()
    try requireRecovery(removedCount == 1, "one dismissed capture removed at termination")
    try requireRecovery(
      try await dismissedQueue.entries().isEmpty, "dismissed journal entry removed")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: dismissedDirectory.path),
      "dismissed source and finalized files removed")

    let retainedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-termination-retained-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: retainedRoot) }
    let retainedCapture = fixtureCapture()
    let retainedImporter = ImportSequence(
      results: [.failed("Photos unavailable")], root: retainedRoot,
      captureID: retainedCapture.uuid)
    let retainedQueue = SaveQueueActor(
      stagingRoot: retainedRoot.appendingPathComponent("staging"),
      importer: { file, _ in await retainedImporter.run(file) })
    try await retainedQueue.enqueue(retainedCapture)
    _ = try await waitForStage(retainedQueue, id: retainedCapture.uuid, [.failedAddingToPhotos])
    try await retainedQueue.dismissFailedCaptureFromProgress(uuid: retainedCapture.uuid)
    try await retainedQueue.restoreRetainedCapture(uuid: retainedCapture.uuid)
    let retainedDirectory = retainedRoot.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(retainedCapture.uuid.uuidString, isDirectory: true)
    if await retainedQueue.beginTermination() {
      await retainedQueue.waitForTerminationWorkToFinish()
    }
    let retainedRemovedCount = try await retainedQueue.discardDismissedCapturesOnTermination()
    let retainedEntry = try await retainedQueue.entries().first
    try requireRecovery(retainedRemovedCount == 0, "restored retained capture is preserved")
    try requireRecovery(
      retainedEntry?.isProgressDismissed == true && retainedEntry?.isRetainedDismissed == false,
      "restored item remains in retained recovery")
    try requireRecovery(
      FileManager.default.fileExists(atPath: retainedDirectory.path),
      "restored source and finalized files remain on disk")
  }

  await test("interruptedDismissedCleanupFinishesOnNextLaunch") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-termination-dismissed-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.failed("Photos unavailable")], root: root, captureID: capture.uuid)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)

    let journalURL = root.appendingPathComponent("journal.json")
    var journal =
      try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
      as! [String: Any]
    var entries = journal["entries"] as! [[String: Any]]
    entries[0]["discardOnTermination"] = true
    journal["entries"] = entries
    try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

    let relaunched = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in .failed("Synthetic importer; Photos access disabled in automated tests") }
    )
    try await relaunched.reconcileOnLaunch()
    let directory = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    try requireRecovery(try await relaunched.entries().isEmpty, "marked row is not recovered")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: directory.path), "interrupted cleanup completes")
  }

  await test("dismissedCapturesAreRemovedDuringNextLaunchReconciliation") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-termination-dismissed-reconcile-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = fixtureCapture()
    let importer = ImportSequence(
      results: [.failed("Photos unavailable")], root: root, captureID: capture.uuid)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await importer.run(file) })
    try await queue.enqueue(capture)
    _ = try await waitForStage(queue, id: capture.uuid, [.failedAddingToPhotos])
    try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
    let sourceDirectory = root.appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(capture.uuid.uuidString, isDirectory: true)

    let relaunched = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in .failed("Synthetic importer; Photos access disabled in automated tests") }
    )
    try await relaunched.reconcileOnLaunch()
    try requireRecovery(
      try await relaunched.entries().isEmpty, "dismissed journal row is removed on relaunch")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: sourceDirectory.path),
      "dismissed staged files are removed on relaunch")
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
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in .failed("Synthetic importer; Photos access disabled in automated tests") }
    )
    do {
      try await queue.reconcileOnLaunch()
      throw RecoveryAssertion.failed("corrupt journal accepted")
    } catch SaveQueueActor.QueueError.journal {}
    try requireRecovery(
      try Data(contentsOf: journal) == corrupt, "corrupt journal bytes left untouched")
  }
}
