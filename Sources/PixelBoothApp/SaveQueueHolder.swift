// Shared singletons: the save queue actor is process-wide so journal
// reconciliation works across window lifetimes. Captures are enqueued by the
// shutter and complete through the queue's encode/validate/import pipeline.
// The Capture Status window observes the durable journal for status and
// exposes its supported recovery actions.

import Foundation
import PixelBoothLibrary
import SwiftUI
import os

struct CaptureProgressItem: Identifiable, Equatable {
  let uuid: UUID
  let stage: SaveQueueActor.Stage
  let updatedAt: Date
  let lastError: String?
  let isPermanentlyUnencodable: Bool

  var id: UUID { uuid }

  var title: String {
    "Capture · \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  var statusText: String {
    if isPermanentlyUnencodable { return "Cannot safely encode this image" }
    switch stage {
    case .capturing: return "Capturing"
    case .capturedLocally: return "Captured locally"
    case .encoding: return "Encoding"
    case .validating: return "Validating image"
    case .addingToPhotos: return "Adding to Photos"
    case .saved: return "Saved to Photos"
    case .failedEncoding: return "Encoding failed"
    case .failedValidating: return "Validation failed"
    case .failedAddingToPhotos:
      return lastError?.contains("Photos access is off") == true
        ? "Photos access is off" : "Photos import failed"
    case .failedDiskFull: return "Not enough disk space"
    case .failedUnsupportedColorDescriptor: return "Cannot safely encode this image"
    case .ambiguousImport: return "Photos status needs confirmation"
    case .exportedOriginal: return "Original saved"
    }
  }

  var isComplete: Bool { stage == .saved }

  var needsAttention: Bool {
    stage.canDismissFromProgress
  }

  var needsDuplicateConfirmation: Bool { stage == .ambiguousImport }

  init(entry: SaveQueueActor.JournalEntry) {
    self.init(
      uuid: entry.uuid, stage: entry.stage, updatedAt: entry.updatedAt,
      lastError: entry.lastError, isPermanentlyUnencodable: entry.isPermanentlyUnencodable)
  }

  init(
    uuid: UUID, stage: SaveQueueActor.Stage, updatedAt: Date,
    lastError: String? = nil, isPermanentlyUnencodable: Bool = false
  ) {
    self.uuid = uuid
    self.stage = stage
    self.updatedAt = updatedAt
    self.lastError = lastError
    self.isPermanentlyUnencodable = isPermanentlyUnencodable
  }
}

@MainActor
final class SaveQueueHolder: ObservableObject {
  static let shared = SaveQueueHolder()
  let queue: SaveQueueActor
  @Published private(set) var progressItems: [CaptureProgressItem] = []
  @Published private(set) var retainedItems: [CaptureProgressItem] = []
  @Published private(set) var dismissedRetainedItems: [CaptureProgressItem] = []
  @Published private(set) var recoveryError: String?
  @Published private(set) var capacityError: String?
  @Published private(set) var photosAuthorizationState: SaveQueueActor.PhotosAuthorizationState =
    .notDetermined

  private let logger = Logger(subsystem: "app.pixelbooth", category: "save-queue")
  private var changeObserver: NSObjectProtocol?
  private var trackedCaptureIDs: Set<UUID> = []
  private var recentlySavedItems: [UUID: CaptureProgressItem] = [:]
  private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
  private var refreshRevision = 0

  init(queue: SaveQueueActor = SaveQueueActor()) {
    self.queue = queue
    changeObserver = NotificationCenter.default.addObserver(
      forName: SaveQueueActor.didChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let savedCaptureIDs = notification.userInfo?["savedCaptureIDs"] as? [String] ?? []
      let reportedError = notification.userInfo?["error"] as? String
      let capacityError = notification.userInfo?["capacityError"] as? String
      Task { @MainActor [weak self] in
        if let reportedError { self?.recoveryError = reportedError }
        if let capacityError { self?.capacityError = capacityError }
        await self?.refreshProgress(savedCaptureIDs: savedCaptureIDs)
        await self?.refreshPhotosAuthorizationStatus()
      }
    }
    Task { await reconcileAndRefresh() }
  }

  func reconcileAndRefresh() async {
    do {
      try await queue.reconcileOnLaunch()
      recoveryError = nil
    } catch {
      recoveryError = error.localizedDescription
      logger.error("Save recovery on launch failed: \(error.localizedDescription)")
    }
    await refreshProgress()
    await refreshPhotosAuthorizationStatus()
  }

  func refreshPhotosAuthorizationStatus() async {
    photosAuthorizationState = await queue.photosAuthorizationStatus()
  }

  func requestPhotosAuthorization() {
    Task { @MainActor in
      photosAuthorizationState = await queue.requestPhotosAuthorization()
    }
  }

  func dismissRetainedCapture(_ item: CaptureProgressItem) {
    Task { @MainActor in
      do {
        try await queue.dismissRetainedCapture(uuid: item.uuid)
        await refreshProgress()
      } catch {
        recoveryError = error.localizedDescription
      }
    }
  }

  func restoreRetainedCapture(_ item: CaptureProgressItem) {
    Task { @MainActor in
      do {
        try await queue.restoreRetainedCapture(uuid: item.uuid)
        await refreshProgress()
      } catch {
        recoveryError = error.localizedDescription
      }
    }
  }

  /// Track a capture before enqueueing so even a very fast save completion is observed.
  func trackCaptureEnqueue(_ uuid: UUID) {
    capacityError = nil
    trackedCaptureIDs.insert(uuid)
    Task { await refreshProgress() }
  }

  func dismissCapacityError() {
    capacityError = nil
  }

  func dismissRecoveryError() {
    recoveryError = nil
  }

  func captureEnqueueFailed(_ uuid: UUID) {
    trackedCaptureIDs.remove(uuid)
  }

  private func refreshProgress(savedCaptureIDs: [String] = []) async {
    refreshRevision += 1
    let revision = refreshRevision
    for savedCaptureID in savedCaptureIDs {
      guard let uuid = UUID(uuidString: savedCaptureID), trackedCaptureIDs.contains(uuid),
        recentlySavedItems[uuid] == nil
      else { continue }
      recentlySavedItems[uuid] = CaptureProgressItem(
        uuid: uuid, stage: .saved, updatedAt: Date())
      scheduleDismissal(for: uuid)
    }

    let entries: [SaveQueueActor.JournalEntry]
    do {
      entries = try await queue.entries()
      if recoveryError?.contains("journal") == true { recoveryError = nil }
    } catch {
      recoveryError = error.localizedDescription
      return
    }
    guard revision == refreshRevision else { return }

    var pendingItems: [CaptureProgressItem] = []
    var retained: [CaptureProgressItem] = []
    var dismissedRetained: [CaptureProgressItem] = []
    for entry in entries {
      guard !entry.isProgressDismissed else {
        trackedCaptureIDs.remove(entry.uuid)
        if entry.stage != .exportedOriginal {
          let item = CaptureProgressItem(entry: entry)
          if entry.isRetainedDismissed {
            dismissedRetained.append(item)
          } else {
            retained.append(item)
          }
        }
        continue
      }
      if entry.stage == .saved {
        guard trackedCaptureIDs.contains(entry.uuid), recentlySavedItems[entry.uuid] == nil else {
          continue
        }
        let item = CaptureProgressItem(entry: entry)
        recentlySavedItems[entry.uuid] = item
        scheduleDismissal(for: entry.uuid)
        continue
      }

      guard entry.stage != .exportedOriginal else {
        trackedCaptureIDs.remove(entry.uuid)
        continue
      }
      trackedCaptureIDs.insert(entry.uuid)
      pendingItems.append(CaptureProgressItem(entry: entry))
    }

    let journalIDs = Set(entries.map(\.uuid))
    trackedCaptureIDs = trackedCaptureIDs.filter {
      journalIDs.contains($0) || recentlySavedItems[$0] != nil
    }
    retainedItems = retained.sorted { $0.updatedAt < $1.updatedAt }
    dismissedRetainedItems = dismissedRetained.sorted { $0.updatedAt < $1.updatedAt }
    publishProgress(pendingItems)
  }

  func retryRecovery() {
    Task {
      await reconcileAndRefresh()
    }
  }

  private func scheduleDismissal(for uuid: UUID) {
    dismissalTasks[uuid]?.cancel()
    dismissalTasks[uuid] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      guard !Task.isCancelled, let self else { return }
      self.recentlySavedItems.removeValue(forKey: uuid)
      self.dismissalTasks.removeValue(forKey: uuid)
      self.trackedCaptureIDs.remove(uuid)
      await self.refreshProgress()
    }
  }

  private func publishProgress(_ pendingItems: [CaptureProgressItem]) {
    let completedItems = Array(recentlySavedItems.values)
    progressItems = (pendingItems + completedItems).sorted { $0.updatedAt < $1.updatedAt }
  }
}
