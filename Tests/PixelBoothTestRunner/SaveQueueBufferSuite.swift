import Foundation
import PixelBoothAVIF
import PixelBoothLibrary

private actor BufferedImportProbe {
  private var firstContinuation: CheckedContinuation<SaveQueueActor.ImportResult, Never>?
  private var firstResult: SaveQueueActor.ImportResult?
  private var activeCount = 0
  private(set) var maximumActiveCount = 0
  private(set) var captureIDs: [UUID] = []
  private(set) var creationDates: [Date] = []

  func run(_ file: URL, date: Date) async -> SaveQueueActor.ImportResult {
    let uuid = UUID(uuidString: file.deletingLastPathComponent().lastPathComponent)!
    captureIDs.append(uuid)
    creationDates.append(date)
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    defer { activeCount -= 1 }
    if captureIDs.count == 1 {
      if let firstResult { return firstResult }
      return await withCheckedContinuation { firstContinuation = $0 }
    }
    return .failed("synthetic import failure; original retained")
  }

  func releaseFirst(_ result: SaveQueueActor.ImportResult = .failed("synthetic import failure")) {
    firstResult = result
    firstContinuation?.resume(returning: result)
    firstContinuation = nil
  }
}

private func bufferedJPEG() -> CapturedCapture {
  CapturedCapture.makeTestCapture(
    fourCC: 0x4d4a_5047, width: 4, height: 4, payload: .jpegBytes(jpegFixture()))
}

private func bufferedAVIF() -> CapturedCapture {
  var capture = CapturedCapture.makeTestCapture(
    fourCC: 0x4e56_3132, width: 4, height: 2,
    payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
  capture.color = CapturedCapture.ColorDescriptor(
    yuvRange: .full, primaries: nil, transfer: nil, matrix: nil,
    chromaLocation: nil, iccProfile: nil)
  return capture
}

private func waitForBufferedStage(
  _ queue: SaveQueueActor, _ capture: CapturedCapture, _ stage: SaveQueueActor.Stage
) async throws -> SaveQueueActor.JournalEntry {
  for _ in 0..<200 {
    if let entry = try await queue.entries().first(where: { $0.uuid == capture.uuid }),
      entry.stage == stage
    {
      return entry
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  throw BufferedQueueAssertion.failed("timed out waiting for \(capture.uuid) at \(stage)")
}

private enum BufferedQueueAssertion: Error { case failed(String) }

func runSaveQueueBufferSuite() async {
  suite("SaveQueueBuffer")

  await test("waitingCapturesAreDurableAndProcessedInOrder") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-buffer-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = BufferedImportProbe()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, date in await probe.run(file, date: date) })
    let captures = [bufferedJPEG(), bufferedAVIF(), bufferedJPEG()]
    do {
      try await queue.enqueue(captures[0])
      _ = try await waitForBufferedStage(queue, captures[0], .addingToPhotos)
      try await queue.enqueue(captures[1])
      try await queue.enqueue(captures[2])
      for capture in captures.dropFirst() {
        let entry = try await waitForBufferedStage(queue, capture, .capturedLocally)
        let directory = URL(fileURLWithPath: entry.stagingPath)
        let staged = try JSONDecoder().decode(
          CapturedCapture.self,
          from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try requireRecovery(
          try encoder.encode(staged) == encoder.encode(capture),
          "waiting source samples, metadata and capture identity are unchanged")
        try requireRecovery(entry.codecFileName == nil, "waiting captures have not been encoded")
      }
      try requireRecovery(await probe.captureIDs == [captures[0].uuid], "only first is active")
      await probe.releaseFirst()
      for capture in captures {
        _ = try await waitForBufferedStage(queue, capture, .failedAddingToPhotos)
      }
      try requireRecovery(
        await probe.captureIDs == captures.map(\.uuid), "captures reach importer in shutter order")
      try requireRecovery(await probe.maximumActiveCount == 1, "one active save pipeline")
      let entry = try await queue.entries().first { $0.uuid == captures[1].uuid }!
      let file = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.avif")
      let decoded = try LosslessAVIF.decode(encoded: [UInt8](Data(contentsOf: file)))
      if case .planes(let snapshot) = captures[1].payload {
        try requireRecovery(decoded.planes == snapshot.contiguous, "buffered native samples exact")
      }
    } catch {
      await probe.releaseFirst()
      _ = await queue.beginTermination()
      await queue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await queue.beginTermination()
    await queue.waitForTerminationWorkToFinish()
  }

  await test("capacityIncludesWaitingOutputsAndReclaimsConfirmedSaves") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-buffer-capacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = BufferedImportProbe()
    let staging = root.appendingPathComponent("staging")
    let queue = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, date in await probe.run(file, date: date) },
      maximumStagedBytes: 25 * 1024 * 1024)
    let captures = [bufferedJPEG(), bufferedJPEG(), bufferedJPEG()]
    do {
      try await queue.enqueue(captures[0])
      _ = try await waitForBufferedStage(queue, captures[0], .addingToPhotos)
      try await queue.enqueue(captures[1])
      do {
        try await queue.enqueue(captures[2])
        throw BufferedQueueAssertion.failed("waiting output reservations were ignored")
      } catch SaveQueueActor.QueueError.capacityExceeded {}
      try requireRecovery(
        !FileManager.default.fileExists(
          atPath: staging.appendingPathComponent(captures[2].uuid.uuidString).path),
        "capacity refusal leaves no orphan source")
      try requireRecovery(try await queue.entries().count == 2, "refusal adds no journal row")
      await probe.releaseFirst(.saved)
      _ = try await waitForBufferedStage(queue, captures[1], .failedAddingToPhotos)
      try requireRecovery(
        !FileManager.default.fileExists(
          atPath: staging.appendingPathComponent(captures[0].uuid.uuidString).path),
        "confirmed save releases staged source and reservation")
      try await queue.enqueue(captures[2])
      _ = try await waitForBufferedStage(queue, captures[2], .failedAddingToPhotos)
    } catch {
      await probe.releaseFirst()
      _ = await queue.beginTermination()
      await queue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await queue.beginTermination()
    await queue.waitForTerminationWorkToFinish()
  }

  await test("quitPreservesWaitingCapturesAndReservationsForRelaunch") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-buffer-relaunch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    let oldProbe = BufferedImportProbe()
    let oldQueue = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, date in await oldProbe.run(file, date: date) },
      maximumStagedBytes: 35 * 1024 * 1024)
    let captures = [bufferedJPEG(), bufferedAVIF(), bufferedJPEG(), bufferedJPEG()]
    do {
      try await oldQueue.enqueue(captures[0])
      _ = try await waitForBufferedStage(oldQueue, captures[0], .addingToPhotos)
      try await oldQueue.enqueue(captures[1])
      try await oldQueue.enqueue(captures[2])
      try requireRecovery(await oldQueue.beginTermination(), "quit waits for the active save")
      do {
        try await oldQueue.enqueue(captures[3])
        throw BufferedQueueAssertion.failed("quit accepted another capture")
      } catch SaveQueueActor.QueueError.terminating {}
      await oldProbe.releaseFirst(.uncertain("synthetic interrupted Photos request"))
      await oldQueue.waitForTerminationWorkToFinish()
      try requireRecovery(await oldProbe.captureIDs.count == 1, "quit does not start waiting saves")
      for capture in captures[1...2] {
        _ = try await waitForBufferedStage(oldQueue, capture, .capturedLocally)
      }
    } catch {
      await oldProbe.releaseFirst()
      _ = await oldQueue.beginTermination()
      await oldQueue.waitForTerminationWorkToFinish()
      throw error
    }
    let newProbe = BufferedImportProbe()
    let newQueue = SaveQueueActor(
      stagingRoot: staging,
      importer: { file, date in await newProbe.run(file, date: date) },
      maximumStagedBytes: 35 * 1024 * 1024)
    do {
      try await newQueue.reconcileOnLaunch()
      _ = try await waitForBufferedStage(newQueue, captures[1], .addingToPhotos)
      try await newQueue.reconcileOnLaunch()
      do {
        try await newQueue.enqueue(captures[3])
        throw BufferedQueueAssertion.failed("relaunch lost outstanding reservations")
      } catch SaveQueueActor.QueueError.capacityExceeded {}
      await newProbe.releaseFirst()
      _ = try await waitForBufferedStage(newQueue, captures[2], .failedAddingToPhotos)
      try requireRecovery(
        await newProbe.captureIDs == captures[1...2].map(\.uuid),
        "relaunch resumes waiting captures once, in order, without retrying ambiguous imports")
      _ = try await waitForBufferedStage(newQueue, captures[0], .ambiguousImport)
    } catch {
      await newProbe.releaseFirst()
      _ = await newQueue.beginTermination()
      await newQueue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await newQueue.beginTermination()
    await newQueue.waitForTerminationWorkToFinish()
  }

  await test("failedEncodingPreservesSourceAndContinuesWaitingWork") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-buffer-failed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = BufferedImportProbe()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, date in await probe.run(file, date: date) })
    var unsupported = bufferedAVIF()
    unsupported.color?.yuvRange = nil
    let captures = [bufferedJPEG(), unsupported, bufferedJPEG()]
    do {
      try await queue.enqueue(captures[0])
      _ = try await waitForBufferedStage(queue, captures[0], .addingToPhotos)
      try await queue.enqueue(captures[1])
      try await queue.enqueue(captures[2])
      await probe.releaseFirst()
      let failed = try await waitForBufferedStage(
        queue, captures[1], .failedUnsupportedColorDescriptor)
      _ = try await waitForBufferedStage(queue, captures[2], .failedAddingToPhotos)
      try requireRecovery(
        FileManager.default.fileExists(
          atPath: URL(fileURLWithPath: failed.stagingPath).appendingPathComponent("capture.json")
            .path),
        "failed encoding preserves the accepted source")
      try requireRecovery(
        await probe.captureIDs == [captures[0].uuid, captures[2].uuid],
        "failed encoding does not stop the next waiting capture")
    } catch {
      await probe.releaseFirst()
      _ = await queue.beginTermination()
      await queue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await queue.beginTermination()
    await queue.waitForTerminationWorkToFinish()
  }

  await test("failedExplicitExportDoesNotStrandWaitingCapture") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-buffer-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = BufferedImportProbe()
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, date in await probe.run(file, date: date) })
    let captures = [bufferedJPEG(), bufferedJPEG()]
    do {
      try await queue.enqueue(captures[0])
      _ = try await waitForBufferedStage(queue, captures[0], .addingToPhotos)
      try await queue.enqueue(captures[1])
      let blocked = root.appendingPathComponent("blocked")
      try Data([0]).write(to: blocked)
      do {
        _ = try await queue.saveOriginal(
          uuid: captures[1].uuid, to: blocked.appendingPathComponent("x.jpg"))
        throw BufferedQueueAssertion.failed("export through a regular file succeeded")
      } catch let error as BufferedQueueAssertion {
        throw error
      } catch {}
      await probe.releaseFirst()
      _ = try await waitForBufferedStage(queue, captures[1], .failedAddingToPhotos)
      try requireRecovery(
        await probe.captureIDs == captures.map(\.uuid), "failed export stays queued")
    } catch {
      await probe.releaseFirst()
      _ = await queue.beginTermination()
      await queue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await queue.beginTermination()
    await queue.waitForTerminationWorkToFinish()
  }
}
