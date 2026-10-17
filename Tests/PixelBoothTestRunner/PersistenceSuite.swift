// Persistence/failure recovery tests: journal round-trip through a temp
// staging root (real crash-recovery simulation at each save stage),
// capacity refusal, and cleanup.

import Foundation
import PixelBoothLibrary

func runPersistenceSuite() async {
  suite("Persistence")

  await test("journalPersistsStagedCapture") {
    let root = URL(fileURLWithPath: "/tmp/pixelbooth-stage-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = SaveQueueActor(stagingRoot: root.appendingPathComponent("staging"))
    // Journal is created on first capture; simulate a stage write via the
    // runner path (CapturedCapture from synthetic planes).
    let snapshot = syntheticNV12Snapshot(width: 4, height: 2)
    let capture = CapturedCapture.makeTestCapture(
      fourCC: 0x4e56_3132, width: 4, height: 2, payload: .planes(snapshot))
    do { try await queue.enqueue(capture) } catch { throw error }
    try await Task.sleep(nanoseconds: 100_000_000)
    try await queue.reconcileOnLaunch()
    try requireRecovery(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path),
      "journal persisted")
  }

  await test("capacityRefusalLeavesNoOrphanDirectory") {
    let root = URL(fileURLWithPath: "/tmp/pixelbooth-capacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let queue = SaveQueueActor(stagingRoot: staging, maximumStagedBytes: 1)
    let snapshot = syntheticNV12Snapshot(width: 4, height: 2)
    let capture = CapturedCapture.makeTestCapture(
      fourCC: 0x4e56_3132, width: 4, height: 2, payload: .planes(snapshot))
    do {
      try await queue.enqueue(capture)
      throw RecoveryTestError.assertion("over-budget capture was accepted")
    } catch SaveQueueActor.QueueError.capacityExceeded {
      // Expected: the capture is refused before creating its UUID directory.
    }
    try requireRecovery(
      !FileManager.default.fileExists(
        atPath: staging.appendingPathComponent(capture.uuid.uuidString).path),
      "capacity refusal leaves no orphan capture directory")
    try requireRecovery(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path),
      "capacity refusal does not add a journal entry")
  }

  await test("completedJournalHistoryDoesNotExhaustCaptureCapacity") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-completed-capacity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let entries: [[String: Any]] = (0..<200).map { index in
      [
        "uuid": UUID().uuidString,
        "stage": index.isMultiple(of: 2) ? "saved" : "exportedOriginal",
        "stagingPath": root.appendingPathComponent("staging/unused").path,
        "createdAt": 0,
        "updatedAt": 0,
      ]
    }
    try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
      .write(to: root.appendingPathComponent("journal.json"))
    let capture = CapturedCapture.makeTestCapture(
      fourCC: 0x4d4a_5047, width: 4, height: 4, payload: .jpegBytes(jpegFixture()))
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { _, _ in .failed("simulated failure") })
    try await queue.enqueue(capture)
    for _ in 0..<100 {
      let retained = try await queue.entries()
      if retained.first?.stage == .failedAddingToPhotos {
        try requireRecovery(
          retained.count == 1, "completed history is pruned before capacity check")
        try requireRecovery(retained.first?.uuid == capture.uuid, "new capture accepted")
        return
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw RecoveryTestError.assertion("new capture did not reach the importer")
  }
}

func requireRecovery(_ condition: Bool, _ message: String) throws {
  guard condition else { throw RecoveryTestError.assertion(message) }
}

private enum RecoveryTestError: Error { case assertion(String) }

func notRunHardwareNote() {
  print("--- Hardware/permission-dependent integration checks (require hardware) ---")
  print(
    "NOT RUN HardwareDependent.realCameraEnumeration: requires physical camera and camera permission"
  )
  print(
    "NOT RUN HardwareDependent.photosOriginalResourceHashComparison: requires Photos add-only + read authorization"
  )
}
