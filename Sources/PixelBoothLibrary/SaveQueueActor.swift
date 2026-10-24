// SaveQueueActor — durable staging and journal; Photos-first save with
// recoverable failure states. Encode, validate, finalize atomically, import,
// and clean up only after confirmed success.

import CryptoKit
import Darwin
import Foundation
import Photos
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCapture
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothMetadata

/// Isolated, high-priority destination worker for explicit Save Original… actions.
/// Streaming copy keeps memory bounded and never overwrites a user-selected file.
private actor SaveAsWorker {
  func exportIfMatching(
    finalizedFile: URL, stagingDirectory: URL, expectedHash: String, to destination: URL
  ) throws -> Bool {
    let accessing = destination.startAccessingSecurityScopedResource()
    defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
    return try Self.durableCopy(
      finalizedFile, stagingDirectory: stagingDirectory,
      expectedHash: expectedHash, to: destination)
  }

  private static func durableCopy(
    _ source: URL, stagingDirectory: URL, expectedHash: String, to destination: URL
  ) throws -> Bool {
    guard !isSymlink(stagingDirectory), !isSymlink(source) else {
      throw SaveQueueActor.QueueError.originalUnavailable("invalid staged path")
    }
    guard FileManager.default.fileExists(atPath: source.path) else { return false }

    let parent = destination.deletingLastPathComponent()
    try ensureDirectoryDurable(parent)
    let temporary = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw SaveQueueActor.QueueError.originalUnavailable("could not create export staging file")
    }

    do {
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: temporary)
      defer { try? output.close() }
      var hasher = SHA256()
      while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
        try output.write(contentsOf: chunk)
        hasher.update(data: chunk)
      }
      let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard actualHash == expectedHash else {
        try output.close()
        try? FileManager.default.removeItem(at: temporary)
        return false
      }
      try output.synchronize()
      guard Darwin.fcntl(output.fileDescriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try output.close()
      guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try synchronizeDirectory(parent)
      let committed = try FileHandle(forReadingFrom: destination)
      defer { try? committed.close() }
      guard Darwin.fcntl(committed.fileDescriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return true
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private static func ensureDirectoryDurable(_ directory: URL) throws {
    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      try synchronizeDirectory(directory)
      return
    }
    if values?.isDirectory == true { return }
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else {
      throw SaveQueueActor.QueueError.originalUnavailable("destination directory is unavailable")
    }
    try ensureDirectoryDurable(parent)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      let check = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard check.isDirectory == true, check.isSymbolicLink != true else { throw error }
    }
    try synchronizeDirectory(parent)
    try synchronizeDirectory(directory)
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(fd) }
    guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}

/// Keeps background integrity reads away from the interactive Save As worker.
private actor StagedFileValidationWorker {
  func matchesHash(file: URL, stagingDirectory: URL, expectedHash: String) throws -> Bool {
    guard !Self.isSymlink(stagingDirectory), !Self.isSymlink(file) else {
      throw SaveQueueActor.QueueError.originalUnavailable("invalid staged path")
    }
    guard FileManager.default.fileExists(atPath: file.path) else { return false }
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var hasher = SHA256()
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return actualHash == expectedHash
  }

  private static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}

/// Serializes all AOM work so Save As can request the same encoder without
/// competing with a background Photos encode or exceeding the thread budget.
private actor AVIFEncodingWorker {
  func encode(
    _ capture: CapturedCapture, exifPayload: [UInt8], xmpPayload: [UInt8]
  ) throws -> (data: [UInt8], settings: LosslessAVIF.AppliedSettings) {
    try capture.encodeAVIF(exifPayload: exifPayload, xmpPayload: xmpPayload)
  }
}

public actor SaveQueueActor {
  public enum PhotosAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted
    case unknown

    public var canAddPhotos: Bool { self == .authorized || self == .limited }

    public var recoveryMessage: String? {
      switch self {
      case .notDetermined:
        return "Allow PixelBooth to add captures to Photos."
      case .denied:
        return
          "Photos access is off. In System Settings, open Privacy & Security > Photos and enable PixelBooth. If PixelBooth is missing, make sure you reopened the latest built PixelBooth.app. Save Original… remains available while Photos access is unavailable."
      case .restricted:
        return
          "Photos access is restricted on this Mac. Check Screen Time or device management settings."
      case .unknown:
        return
          "Photos authorization status is unavailable. Check System Settings > Privacy & Security > Photos."
      case .authorized, .limited:
        return nil
      }
    }
  }

  /// Save states, distinct and recoverable; no invented percentage.
  public enum Stage: String, Codable, Sendable {
    case capturing
    case capturedLocally
    case encoding
    case validating
    case addingToPhotos
    case saved
    case savedWithMetadataReport
    case failedEncoding
    case failedValidating
    case failedAddingToPhotos
    case failedDiskFull
    case failedUnsupportedColorDescriptor
    case ambiguousImport
    case exportedOriginal

    public var canDismissFromProgress: Bool {
      switch self {
      case .failedEncoding, .failedValidating, .failedAddingToPhotos, .failedDiskFull,
        .failedUnsupportedColorDescriptor, .ambiguousImport, .savedWithMetadataReport:
        return true
      default:
        return false
      }
    }
  }

  public struct JournalEntry: Codable, Sendable {
    public var uuid: UUID
    public var stage: Stage
    public var stagingPath: String
    public var fileHashSHA256: String?
    public var codec: String?
    public var encoderSettings: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var codecFileName: String?
    public var lastError: String?
    public var progressDismissed: Bool?
    public var retainedDismissed: Bool?
    public var discardOnTermination: Bool?
    /// Source, output and temporary-file allowance retained across relaunches.
    /// Optional for journals written before buffered capture admission.
    public var stagingReservationBytes: UInt64?
    public var hasMetadataReport: Bool?

    public var isProgressDismissed: Bool { progressDismissed ?? false }
    public var isRetainedDismissed: Bool { retainedDismissed ?? false }
    public var shouldDiscardOnTermination: Bool { discardOnTermination ?? false }

    public var isPermanentlyUnencodable: Bool {
      if stage == .failedUnsupportedColorDescriptor { return hasMetadataReport != true }
      guard stage == .failedEncoding, let lastError else { return false }
      let normalized = lastError.lowercased()
      return normalized == "snapshoterror 1" || normalized.contains("snapshoterror error 1")
    }

    init(
      uuid: UUID, stage: Stage, stagingPath: String,
      fileHashSHA256: String? = nil, codec: String? = nil,
      encoderSettings: String? = nil, createdAt: Date, updatedAt: Date,
      codecFileName: String? = nil, lastError: String? = nil,
      progressDismissed: Bool? = nil, retainedDismissed: Bool? = nil,
      discardOnTermination: Bool? = nil, stagingReservationBytes: UInt64? = nil,
      hasMetadataReport: Bool? = nil
    ) {
      self.uuid = uuid
      self.stage = stage
      self.stagingPath = stagingPath
      self.fileHashSHA256 = fileHashSHA256
      self.codec = codec
      self.encoderSettings = encoderSettings
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.codecFileName = codecFileName
      self.lastError = lastError
      self.progressDismissed = progressDismissed
      self.retainedDismissed = retainedDismissed
      self.discardOnTermination = discardOnTermination
      self.stagingReservationBytes = stagingReservationBytes
      self.hasMetadataReport = hasMetadataReport
    }
  }

  public enum ImportResult: Sendable, Equatable {
    case saved
    case failed(String)
    case uncertain(String)
  }

  public enum QueueError: Error, LocalizedError, Sendable {
    case busy
    case capacityExceeded
    case terminating
    case staging(String)
    case journal(String)
    case invalidCapture(UUID)
    case missingOriginal(UUID)
    case ambiguousNeedsConfirmation
    case originalUnavailable(String)

    public var errorDescription: String? {
      switch self {
      case .busy: return "The save queue is busy. Try again shortly."
      case .capacityExceeded:
        return
          "The local capture staging limit has been reached. Wait for pending saves to finish, or save or remove retained originals, then try again."
      case .terminating: return "PixelBooth is finishing active captures before quitting."
      case .staging(let reason): return "Capture could not be stored safely: \(reason)"
      case .journal(let reason): return "The recovery journal is unavailable: \(reason)"
      case .invalidCapture(let id): return "Staged capture \(id) is invalid and was retained."
      case .missingOriginal(let id): return "No staged original exists for capture \(id)."
      case .ambiguousNeedsConfirmation:
        return
          "The previous Photos request may have completed. Confirm a possible duplicate before retrying."
      case .originalUnavailable(let reason): return "The original could not be prepared: \(reason)"
      }
    }
  }

  private struct JournalDocument: Codable {
    var version: Int
    var entries: [JournalEntry]
  }

  private static let changedNotification = Notification.Name("PixelBoothSaveQueueDidChange")
  public static var didChangeNotification: Notification.Name { changedNotification }

  /// One active save pipeline, with AVIF work serialized by its own worker.
  /// Waiting capture admission is independent of this processing limit.
  private var inFlightCount = 0
  private var maxInFlight = 1
  private var activeCaptures: Set<UUID> = []
  private var saveAsInProgress = false
  private var terminationRequested = false
  private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
  /// Waiting payloads live in durable staging, not in an in-memory image array.
  /// The journal count and cumulative disk reservations bound this FIFO.
  private var pendingCaptureIDs: [UUID] = []
  private var stagingRoot: URL
  private let saveAsWorker = SaveAsWorker()
  private let stagedFileValidationWorker = StagedFileValidationWorker()
  private let avifEncodingWorker = AVIFEncodingWorker()
  private let journalMaxEntries = 200
  private let maximumStagedBytes: UInt64
  private let testImporter: (@Sendable (URL, Date) async -> ImportResult)?
  private let testPhotosAuthorizationProvider: (@Sendable (Bool) async -> PhotosAuthorizationState)?

  public init(
    stagingRoot: URL? = nil,
    importer: (@Sendable (URL, Date) async -> ImportResult)? = nil,
    maximumStagedBytes: UInt64 = 512 * 1024 * 1024,
    photosAuthorizationProvider: (@Sendable (Bool) async -> PhotosAuthorizationState)? = nil
  ) {
    self.testImporter = importer
    self.testPhotosAuthorizationProvider = photosAuthorizationProvider
    self.maximumStagedBytes = maximumStagedBytes
    if let stagingRoot {
      self.stagingRoot = stagingRoot
    } else {
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      self.stagingRoot = appSupport.appendingPathComponent("PixelBooth/staging", isDirectory: true)
    }
  }

  /// Stop accepting work and finish the active save. Waiting sources remain
  /// durably staged for the next launch rather than prolonging termination.
  public func beginTermination() -> Bool {
    terminationRequested = true
    return inFlightCount > 0 || saveAsInProgress
  }

  /// Wait until active queue processing and any explicit Save Original operation finish.
  public func waitForTerminationWorkToFinish() async {
    guard terminationRequested, inFlightCount > 0 || saveAsInProgress else { return }
    await withCheckedContinuation { continuation in
      terminationWaiters.append(continuation)
    }
  }

  /// Remove captures explicitly dismissed from retained recovery when the app
  /// is quitting. The journal marker makes cleanup recoverable if termination
  /// is interrupted after intent is recorded but before staged data is removed.
  @discardableResult
  public func discardDismissedCapturesOnTermination() throws -> Int {
    guard terminationRequested else { throw QueueError.terminating }
    guard inFlightCount == 0, !saveAsInProgress, activeCaptures.isEmpty else {
      throw QueueError.busy
    }

    var entries = try readJournal()
    let dismissedIDs = Set(
      entries.filter {
        $0.shouldDiscardOnTermination
          || ($0.isProgressDismissed && $0.isRetainedDismissed
            && $0.stage != .saved && $0.stage != .exportedOriginal)
      }.map(\.uuid))
    guard !dismissedIDs.isEmpty else { return 0 }

    for index in entries.indices where dismissedIDs.contains(entries[index].uuid) {
      entries[index].discardOnTermination = true
      entries[index].updatedAt = Date()
    }
    try writeJournal(entries)

    for uuid in dismissedIDs {
      try removeStagingDirectoryForTermination(uuid)
    }

    entries.removeAll { $0.shouldDiscardOnTermination }
    try writeJournal(entries)
    return dismissedIDs.count
  }

  /// Names of the exact locally staged files a confirmed discard will remove.
  /// Exported originals live outside the staging directory and are never listed.
  public func retainedFilesForDeletion(uuid: UUID) throws -> [String] {
    try requireDeletionIdle()
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard entry.isProgressDismissed, entry.stage != .saved, entry.stage != .exportedOriginal else {
      throw QueueError.originalUnavailable("only retained recovery captures can be deleted")
    }
    return try checkedStagingChildren(for: entry).map(\.lastPathComponent)
  }

  /// Durably records delete intent before removing any staged source or
  /// finalized image. A crash or partial filesystem failure cannot schedule an
  /// intentionally deleted capture for encoding or Photos import.
  public func deleteRetainedCapture(uuid: UUID) throws {
    guard !terminationRequested else { throw QueueError.terminating }
    try requireDeletionIdle()
    var entries = try readJournal()
    guard let index = entries.firstIndex(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard entries[index].isProgressDismissed,
      entries[index].stage != .saved, entries[index].stage != .exportedOriginal
    else {
      throw QueueError.originalUnavailable("only retained recovery captures can be deleted")
    }
    _ = try checkedStagingChildren(for: entries[index])
    entries[index].discardOnTermination = true
    entries[index].updatedAt = Date()
    try writeJournal(entries)

    try removeStagingDirectoryForTermination(uuid)
    entries.removeAll { $0.uuid == uuid }
    try writeJournal(entries)
  }

  private func requireDeletionIdle() throws {
    guard inFlightCount == 0, !saveAsInProgress, activeCaptures.isEmpty else {
      throw QueueError.busy
    }
  }

  private func resumeTerminationWaitersIfIdle() {
    guard terminationRequested, inFlightCount == 0, !saveAsInProgress else { return }
    let waiters = terminationWaiters
    terminationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Enqueue a capture; refuses when at capacity with a clear explanation.
  public func enqueue(_ capture: CapturedCapture) async throws {
    guard !terminationRequested else { throw QueueError.terminating }
    try writeStagingAndJournal(capture)
    pendingCaptureIDs.append(capture.uuid)
    pumpPendingWork()
  }

  private func reportCapacityExhausted() {
    // A queue-wide status is separate from any one capture's save stage.
    NotificationCenter.default.post(
      name: Self.changedNotification,
      object: nil,
      userInfo: [
        "capacityError": QueueError.capacityExceeded.localizedDescription
      ])
  }

  private func capacityExceededError() -> QueueError {
    reportCapacityExhausted()
    return .capacityExceeded
  }

  /// Write the immutable source snapshot and journal entry durably before
  /// treating the capture as safely queued.
  private func writeStagingAndJournal(_ capture: CapturedCapture) throws {
    let dir = stagingRoot.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    do {
      try ensureDirectoryDurable(stagingRoot, rejectSymlinkAtTarget: true)
      guard !(try readJournal()).contains(where: { $0.uuid == capture.uuid }),
        !FileManager.default.fileExists(atPath: dir.path)
      else {
        throw QueueError.staging("capture UUID already has staged data")
      }
      let data = try JSONEncoder().encode(capture)
      let existing = try readJournal().filter {
        $0.stage != .saved && $0.stage != .exportedOriginal
      }
      guard existing.count < journalMaxEntries else { throw capacityExceededError() }
      let used = try reservedStagedByteCount(entries: existing)
      let required = try stagingCapacityReservation(for: capture, encodedSourceBytes: data.count)
      guard used <= maximumStagedBytes, required <= maximumStagedBytes - used else {
        throw capacityExceededError()
      }
      try ensureDirectoryDurable(dir, rejectSymlinkAtTarget: true)
      try synchronizeDirectory(stagingRoot)
      try durableAtomicWrite(data, to: dir.appendingPathComponent("capture.json"))
      if capture.hasMetadataReport {
        try durableAtomicWrite(
          capture.metadataReportData(), to: dir.appendingPathComponent("metadata-report.json"))
      }
      try upsertJournal(
        JournalEntry(
          uuid: capture.uuid, stage: .capturedLocally,
          stagingPath: dir.path, createdAt: Date(), updatedAt: Date(),
          stagingReservationBytes: required, hasMetadataReport: capture.hasMetadataReport))
      NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    } catch let error as QueueError {
      throw error
    } catch {
      throw QueueError.staging(error.localizedDescription)
    }
  }

  /// Encode + validate + import. Cleanup only after confirmed success.
  private func process(_ capture: CapturedCapture) async {
    defer {
      inFlightCount = max(0, inFlightCount - 1)
      activeCaptures.remove(capture.uuid)
      Task { self.pumpPendingWork() }
    }
    var importWasAttempted = false
    do {
      try updateJournal(capture.uuid, stage: .encoding)
      let finalized: (url: URL, hashHex: String, codec: String, settings: String)
      if let stored = try await existingFinalized(capture.uuid) {
        finalized = stored
      } else {
        finalized = try await finalize(capture)
      }
      try updateJournal(
        capture.uuid, stage: .validating, fileHash: finalized.hashHex,
        codec: finalized.codec, settings: finalized.settings,
        fileName: finalized.url.lastPathComponent)
      guard !finalized.hashHex.isEmpty else {
        throw QueueError.originalUnavailable("finalized file has no hash")
      }
      try updateJournal(capture.uuid, stage: .addingToPhotos, fileHash: finalized.hashHex)
      importWasAttempted = true
      switch await importIntoPhotos(fileURL: finalized.url, creationDate: captureDate(capture)) {
      case .saved:
        if capture.hasMetadataReport {
          try updateJournal(
            capture.uuid, stage: .savedWithMetadataReport, fileHash: finalized.hashHex,
            error: capture.metadataWarningSummary)
        } else {
          try updateJournal(capture.uuid, stage: .saved, fileHash: finalized.hashHex)
          try? FileManager.default.removeItem(at: stagingDirectory(capture.uuid))
        }
      case .failed(let message):
        try updateJournal(
          capture.uuid, stage: .failedAddingToPhotos,
          fileHash: finalized.hashHex, error: message)
      case .uncertain(let message):
        try updateJournal(
          capture.uuid, stage: .ambiguousImport,
          fileHash: finalized.hashHex, error: message)
      }
    } catch {
      // If PhotoKit may have received the request, keep the durable stage at
      // addingToPhotos. Relaunch will expose it as ambiguous and never retry
      // automatically, including when recording confirmed success failed.
      if !importWasAttempted {
        let stage: Stage
        switch error as? CapturedCapture.SnapshotError {
        case .unsupportedColorDescriptor?, .conflictingColorDescriptor?:
          stage = .failedUnsupportedColorDescriptor
        default:
          stage = .failedEncoding
        }
        try? updateJournal(capture.uuid, stage: stage, error: error.localizedDescription)
      }
      NotificationCenter.default.post(
        name: Self.changedNotification, object: nil,
        userInfo: ["error": error.localizedDescription])
    }
  }

  /// Produce the finalized file from the immutable payload:
  /// - MJPEG: JPEG passthrough with documented additional XMP metadata.
  /// - Uncompressed: lossless AVIF with verified native-channel round trip.
  private func finalize(_ capture: CapturedCapture) async throws -> (
    url: URL, hashHex: String, codec: String, settings: String
  ) {
    let dir = stagingRoot.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    switch capture.payload {
    case .jpegBytes(let bytes):
      // Metadata-only addition; image-coding data stays byte-exact. Never
      // replace or rewrite camera Exif (it may contain unknown tags or
      // MakerNotes). When no source Exif exists, add a standards-based Exif
      // block with the host capture time and optional accepted location.
      let jpegStructure = try JPEGParser.parse(bytes)
      let generatedExif: [UInt8] =
        jpegStructure.exifSegment == nil
        ? ExifBuilder.build(
          make: capture.metadata.deviceIdentity?.manufacturer
            ?? capture.metadata.hostObservedDeviceMake,
          model: capture.metadata.deviceIdentity?.model ?? capture.metadata.hostObservedDeviceModel,
          software: "PixelBooth \(AppVersion.current)",
          captureISO: capture.acceptedAtISO,
          location: capture.metadata.hostLocation)
        : []
      let additionalExif = generatedExif.isEmpty ? nil : generatedExif
      let xmp = PixelBoothXMP.build(
        captureUUID: capture.uuid, appVersion: AppVersion.current,
        captureBackend: capture.metadata.captureBackend ?? "unknown",
        backendVersion: capture.metadata.captureBackendVersion ?? "unknown",
        libavifVersion: LosslessAVIF.libraryVersion,
        actualCaptureFormat:
          "\(CaptureFormat.fourCCString(capture.pixelFourCC ?? capture.fourCC)) \(capture.width)×\(capture.height)",
        encoderSettings: "metadata-only",
        metadataProvenance: try Self.deviceIdentityProvenance(capture)
          + capture.archivedMetadataProvenance(),
        fidelity: capture.acquisitionEvidence.map { Self.fidelityName($0.fidelity) } ?? "unknown",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO,
        sourceFormat: CaptureFormat.fourCCString(capture.fourCC),
        dataSource: String(describing: capture.dataSource ?? .unknown))
      let withMeta = try JPEGMetadataWriter.withAdditionalMetadata(
        original: bytes, additionalXMP: xmp, additionalExif: additionalExif)
      let url = dir.appendingPathComponent("capture.jpg")
      try durableAtomicWrite(Data(withMeta), to: url)
      let digest = SHA256.hash(data: withMeta)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      return (url, hex, "jpeg-passthrough", "metadata-only")

    case .planes(let snapshot):
      let dimensions = try snapshot.nativeDimensions()
      // Lossless AVIF from planes, verified by exact native-channel decode.
      // Metadata: the same application XMP provenance model as the JPEG path,
      // plus Exif carrying the host-observed device identity and capture time
      // (Photos reads Exif; the XMP labels that provenance as host-observed —
      // never presented as camera-provided metadata).
      let provenance =
        try Self.deviceIdentityProvenance(capture) + capture.archivedMetadataProvenance()
      let xmp = PixelBoothXMP.build(
        captureUUID: capture.uuid, appVersion: AppVersion.current,
        captureBackend: capture.metadata.captureBackend ?? "unknown",
        backendVersion: capture.metadata.captureBackendVersion ?? "unknown",
        libavifVersion: LosslessAVIF.libraryVersion,
        actualCaptureFormat:
          "\(CaptureFormat.fourCCString(capture.pixelFourCC ?? capture.fourCC)) \(dimensions.width)×\(dimensions.height)",
        encoderSettings: "quality=100 speed=0 (lossless, round-trip verified)",
        metadataProvenance: provenance,
        fidelity: capture.acquisitionEvidence.map { Self.fidelityName($0.fidelity) } ?? "unknown",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO,
        sourceFormat: CaptureFormat.fourCCString(capture.fourCC),
        dataSource: String(describing: capture.dataSource ?? .unknown))
      let exif = ExifBuilder.build(
        make: capture.metadata.deviceIdentity?.manufacturer
          ?? capture.metadata.hostObservedDeviceMake,
        model: capture.metadata.deviceIdentity?.model ?? capture.metadata.hostObservedDeviceModel,
        software: "PixelBooth \(AppVersion.current)",
        captureISO: capture.acceptedAtISO,
        location: capture.metadata.hostLocation)
      let (data, settings) = try await avifEncodingWorker.encode(
        capture, exifPayload: exif, xmpPayload: xmp)
      let url = dir.appendingPathComponent("capture.avif")
      try durableAtomicWrite(Data(data), to: url)
      let digest = SHA256.hash(data: data)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      return (url, hex, settings.codec, "quality=\(settings.quality) speed=\(settings.speed)")
    }
  }

  /// PhotoKit original-resource creation with the finished file — never an
  /// NSImage/CGImage round trip. Minimum authorization: add-only on macOS.
  private func importIntoPhotos(fileURL: URL, creationDate: Date) async -> ImportResult {
    var status = await photosAuthorizationStatus()
    if status == .notDetermined { status = await requestPhotosAuthorization() }
    guard status.canAddPhotos else {
      return .failed(status.recoveryMessage ?? "Photos add-only access is unavailable.")
    }
    if let testImporter { return await testImporter(fileURL, creationDate) }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileURL.lastPathComponent
        request.addResource(with: .photo, fileURL: fileURL, options: options)
        request.creationDate = creationDate
      } completionHandler: { success, error in
        if success && error == nil {
          continuation.resume(returning: .saved)
        } else {
          continuation.resume(
            returning: .failed(error?.localizedDescription ?? "Photos import failed"))
        }
      }
    }
  }

  public func photosAuthorizationStatus() async -> PhotosAuthorizationState {
    if let testPhotosAuthorizationProvider {
      return await testPhotosAuthorizationProvider(false)
    }
    if testImporter != nil { return .authorized }
    return Self.mapPhotosAuthorization(PHPhotoLibrary.authorizationStatus(for: .addOnly))
  }

  public func requestPhotosAuthorization() async -> PhotosAuthorizationState {
    if let testPhotosAuthorizationProvider {
      return await testPhotosAuthorizationProvider(true)
    }
    if testImporter != nil { return .authorized }
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    return Self.mapPhotosAuthorization(status)
  }

  private static func mapPhotosAuthorization(
    _ status: PHAuthorizationStatus
  ) -> PhotosAuthorizationState {
    switch status {
    case .notDetermined: return .notDetermined
    case .authorized: return .authorized
    case .limited: return .limited
    case .denied: return .denied
    case .restricted: return .restricted
    @unknown default: return .unknown
    }
  }

  /// Journal file, versioned, crash-recoverable, bounded disk usage.
  private var journalURL: URL {
    stagingRoot.deletingLastPathComponent().appendingPathComponent("journal.json")
  }

  public func entries() throws -> [JournalEntry] { try readJournal() }

  private func readJournal() throws -> [JournalEntry] {
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
    do {
      let data = try Data(contentsOf: journalURL)
      if let doc = try? JSONDecoder().decode(JournalDocument.self, from: data) {
        guard doc.version == 1 else {
          throw QueueError.journal("unsupported journal version \(doc.version)")
        }
        return doc.entries
      }
      return try JSONDecoder().decode([JournalEntry].self, from: data)  // legacy array
    } catch let error as QueueError {
      throw error
    } catch {
      throw QueueError.journal("\(journalURL.path): \(error.localizedDescription)")
    }
  }

  private func writeJournal(_ entries: [JournalEntry]) throws {
    let data = try JSONEncoder().encode(JournalDocument(version: 1, entries: entries))
    do { try durableAtomicWrite(data, to: journalURL) } catch {
      throw QueueError.journal("\(journalURL.path): \(error.localizedDescription)")
    }
    // Carry completion IDs with the event: a subsequent enqueue may prune saved
    // journal rows before the main-actor presentation model reads the journal.
    let savedCaptureIDs = entries.filter { $0.stage == .saved }.map { $0.uuid.uuidString }
    NotificationCenter.default.post(
      name: Self.changedNotification, object: nil,
      userInfo: ["savedCaptureIDs": savedCaptureIDs])
  }

  private func upsertJournal(_ entry: JournalEntry) throws {
    var entries = try readJournal()
    if let index = entries.firstIndex(where: { $0.uuid == entry.uuid }) {
      entries[index] = entry
    } else {
      entries.removeAll { $0.stage == .saved || $0.stage == .exportedOriginal }
      guard entries.count < journalMaxEntries else { throw QueueError.busy }
      entries.append(entry)
    }
    try writeJournal(entries)
  }

  private func updateJournal(
    _ uuid: UUID, stage: Stage, stagingPath: String? = nil,
    fileHash: String? = nil, codec: String? = nil,
    settings: String? = nil, fileName: String? = nil,
    error: String? = nil
  ) throws {
    var entries = try readJournal()
    if let idx = entries.firstIndex(where: { $0.uuid == uuid }) {
      entries[idx].stage = stage
      entries[idx].updatedAt = Date()
      if let stagingPath { entries[idx].stagingPath = stagingPath }
      if let fileHash { entries[idx].fileHashSHA256 = fileHash }
      if let codec { entries[idx].codec = codec }
      if let settings { entries[idx].encoderSettings = settings }
      if let fileName { entries[idx].codecFileName = fileName }
      entries[idx].lastError = error
    } else {
      entries.append(
        JournalEntry(
          uuid: uuid, stage: stage,
          stagingPath: stagingPath ?? stagingDirectory(uuid).path,
          fileHashSHA256: fileHash, codec: codec, encoderSettings: settings,
          createdAt: Date(), updatedAt: Date(), codecFileName: fileName, lastError: error))
    }
    try writeJournal(entries)
  }

  private func stagingDirectory(_ uuid: UUID) -> URL {
    stagingRoot.appendingPathComponent(uuid.uuidString, isDirectory: true)
  }

  private func removeStagingDirectoryForTermination(_ uuid: UUID) throws {
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }) else { return }
    let directory = stagingDirectory(uuid).standardizedFileURL
    _ = try checkedStagingChildren(for: entry)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
      try synchronizeDirectory(stagingRoot)
    } catch let error as QueueError {
      throw error
    } catch {
      throw QueueError.staging(
        "could not remove dismissed capture \(uuid.uuidString): \(error.localizedDescription)")
    }
  }

  private func checkedStagingChildren(for entry: JournalEntry) throws -> [URL] {
    let root = stagingRoot.standardizedFileURL
    let directory = stagingDirectory(entry.uuid).standardizedFileURL
    guard directory.deletingLastPathComponent().path == root.path,
      URL(fileURLWithPath: entry.stagingPath).standardizedFileURL.path == directory.path
    else {
      throw QueueError.staging("capture staging path does not match its journal UUID")
    }
    guard !isSymlink(root), !isSymlink(directory) else {
      throw QueueError.staging("capture staging path contains a symbolic link")
    }
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw QueueError.staging("capture staging path is not a regular directory")
    }
    let allowedNames: Set<String> = [
      "capture.json", "capture.jpg", "capture.avif", "metadata-report.json",
    ]
    let children = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [])
    for child in children {
      let childValues = try child.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard
        allowedNames.contains(child.lastPathComponent)
          || isKnownAtomicTemporaryName(child.lastPathComponent),
        childValues.isRegularFile == true,
        childValues.isSymbolicLink != true
      else {
        throw QueueError.staging(
          "capture staging directory contains an unexpected or symbolic-link item")
      }
    }
    return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func isKnownAtomicTemporaryName(_ name: String) -> Bool {
    for destination in ["capture.json", "capture.jpg", "capture.avif", "metadata-report.json"] {
      let prefix = ".\(destination)."
      guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { continue }
      let identifierStart = name.index(name.startIndex, offsetBy: prefix.count)
      let identifierEnd = name.index(name.endIndex, offsetBy: -4)
      guard identifierStart <= identifierEnd,
        UUID(uuidString: String(name[identifierStart..<identifierEnd])) != nil
      else { continue }
      return true
    }
    return false
  }

  private func durableAtomicWrite(_ data: Data, to destination: URL) throws {
    let parent = destination.deletingLastPathComponent()
    try ensureDirectoryDurable(parent)
    let temporary = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw QueueError.staging("could not create temporary file at \(temporary.path)")
    }
    do {
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      guard Darwin.fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try handle.close()
      guard Darwin.rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try synchronizeDirectory(parent)
      let committed = try FileHandle(forReadingFrom: destination)
      defer { try? committed.close() }
      guard Darwin.fcntl(committed.fileDescriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  /// Create one path component at a time and durably record each directory
  /// entry in its parent. This covers fresh Application Support roots where
  /// both `PixelBooth` and `staging` may be absent.
  private func ensureDirectoryDurable(_ directory: URL, rejectSymlinkAtTarget: Bool = false) throws
  {
    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      guard !rejectSymlinkAtTarget else {
        throw QueueError.staging("staging path contains a symbolic link")
      }
      try synchronizeDirectory(directory)
      return
    }
    if values?.isDirectory == true {
      return
    }
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else {
      throw QueueError.staging("directory root is unavailable")
    }
    try ensureDirectoryDurable(parent)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      let check = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard check.isDirectory == true, check.isSymbolicLink != true else { throw error }
    }
    try synchronizeDirectory(parent)
    try synchronizeDirectory(directory)
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(fd) }
    guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private func stagedByteCounts() throws -> [String: UInt64] {
    let items = try FileManager.default.contentsOfDirectory(
      at: stagingRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [])
    return items.reduce(into: [String: UInt64]()) { counts, item in
      guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isSymbolicLink != true
      else { return }
      var subtotal = UInt64(
        max(0, (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
      if values.isDirectory == true {
        let enumerator = FileManager.default.enumerator(
          at: item, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        while let child = enumerator?.nextObject() as? URL {
          guard let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
            v.isSymbolicLink != true
          else { continue }
          let (next, overflow) = subtotal.addingReportingOverflow(
            UInt64(max(0, v.fileSize ?? 0)))
          subtotal = overflow ? UInt64.max : next
        }
      }
      counts[item.lastPathComponent] = subtotal
    }
  }

  /// Count actual staging plus the unused portion of every outstanding
  /// reservation. Merely counting existing files would let many small source
  /// snapshots consume the space promised for waiting images' finalization.
  private func reservedStagedByteCount(entries: [JournalEntry]) throws -> UInt64 {
    let counts = try stagedByteCounts()
    var total: UInt64 = 0
    for count in counts.values {
      let (next, overflow) = total.addingReportingOverflow(count)
      guard !overflow else { throw capacityExceededError() }
      total = next
    }
    for entry in entries {
      let stored = counts[entry.uuid.uuidString] ?? 0
      let reservation: UInt64
      if let recorded = entry.stagingReservationBytes {
        reservation = recorded
      } else if let capture = try? loadCapture(entry.uuid) {
        // Legacy journals have no reservation. Reconstruct it one source at a
        // time so admission remains bounded even after an interrupted old save.
        let source = stagingDirectory(entry.uuid).appendingPathComponent("capture.json")
        let sourceBytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        reservation = try stagingCapacityReservation(
          for: capture, encodedSourceBytes: max(0, sourceBytes))
      } else {
        reservation = stored
      }
      if reservation > stored {
        let (next, overflow) = total.addingReportingOverflow(reservation - stored)
        guard !overflow else { throw capacityExceededError() }
        total = next
      }
    }
    return total
  }

  /// Reserve local source JSON, a conservative encoded output allowance, the
  /// temporary output used by atomic finalization, and bounded journal space.
  /// The limit is checked before creating the per-capture directory so a
  /// refused capture leaves no orphan staging folder.
  private func stagingCapacityReservation(
    for capture: CapturedCapture, encodedSourceBytes: Int
  ) throws -> UInt64 {
    let sourceBytes: UInt64
    switch capture.payload {
    case .jpegBytes(let bytes):
      sourceBytes = UInt64(bytes.count)
    case .planes(let snapshot):
      sourceBytes = try snapshot.contiguous.reduce(into: UInt64(0)) { total, plane in
        let (next, overflow) = total.addingReportingOverflow(UInt64(plane.count))
        guard !overflow else { throw capacityExceededError() }
        total = next
      }
    }
    let (doubledOutput, outputOverflow) = sourceBytes.multipliedReportingOverflow(by: 2)
    guard !outputOverflow else { throw capacityExceededError() }
    var outputReserve = max(doubledOutput, 4 * 1024 * 1024)
    if capture.metadata.attachmentArchive != nil || capture.metadata.deviceIdentity != nil
      || capture.metadata.streamColorObservations != nil
    {
      let metadataBytes = try JSONEncoder().encode(capture.metadata).count
      let (metadataReserve, overflow) = UInt64(metadataBytes).multipliedReportingOverflow(by: 8)
      let (withMetadata, additionOverflow) = outputReserve.addingReportingOverflow(metadataReserve)
      guard !overflow, !additionOverflow else { throw capacityExceededError() }
      outputReserve = withMetadata
    }
    let (sourceAndOutput, firstOverflow) = UInt64(encodedSourceBytes).addingReportingOverflow(
      outputReserve)
    let (withTemporary, secondOverflow) = sourceAndOutput.addingReportingOverflow(outputReserve)
    let (required, thirdOverflow) = withTemporary.addingReportingOverflow(2 * 1024 * 1024)
    guard !firstOverflow, !secondOverflow, !thirdOverflow else {
      throw capacityExceededError()
    }
    return required
  }

  private func captureDate(_ capture: CapturedCapture) -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: capture.acceptedAtISO) { return parsed }
    let legacy = ISO8601DateFormatter()
    legacy.formatOptions = [.withInternetDateTime]
    return legacy.date(from: capture.acceptedAtISO) ?? Date()
  }

  private static func fidelityName(_ fidelity: AcquisitionFidelity) -> String {
    switch fidelity {
    case .nativePreserved: return "nativePreserved"
    case .macDeliveredConverted: return "macDeliveredConverted"
    case .macDeliveredUnknownUpstream: return "macDeliveredUnknownUpstream"
    }
  }

  /// Host-observed device identity provenance for the application XMP. The
  /// backend-reported device manufacturer/name are labeled hostObserved; the
  /// Exif mirror is labeled applicationGenerated.
  private static func deviceIdentityProvenance(_ capture: CapturedCapture) -> [MetadataObservation]
  {
    var provenance: [MetadataObservation] = []
    if let make = capture.metadata.hostObservedDeviceMake, !make.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceMake", rawValueString: make, provenance: .hostObserved))
    }
    if let model = capture.metadata.hostObservedDeviceModel, !model.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceModel", rawValueString: model, provenance: .hostObserved))
    }
    if let modelID = capture.metadata.hostObservedDeviceModelID, !modelID.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceModelID", rawValueString: modelID, provenance: .hostObserved))
    }
    if let usb = capture.metadata.usbIdentity {
      let values: [(String, String?)] = [
        ("USBVendorID", String(format: "0x%04X", usb.vendorID)),
        ("USBProductID", String(format: "0x%04X", usb.productID)),
        ("USBLocationID", String(format: "0x%08X", usb.locationID)),
        ("USBManufacturerString", usb.manufacturer), ("USBProductString", usb.productName),
        ("USBAssociationMethod", usb.associationMethod),
      ]
      for (key, value) in values {
        if let value {
          provenance.append(
            MetadataObservation(
              key: key, rawValueString: value, provenance: .hostObserved,
              observedAtISO: usb.observedAtISO))
        }
      }
    }
    if let identity = capture.metadata.deviceIdentity {
      if let value = identity.manufacturer, let source = identity.manufacturerSource {
        provenance.append(
          MetadataObservation(
            key: "ResolvedDeviceMake", rawValueString: value,
            provenance: source.provenance))
        provenance.append(
          MetadataObservation(
            key: "DeviceMakeSource", rawValueString: source.rawValue,
            provenance: .applicationGenerated))
      }
      if let value = identity.model, let source = identity.modelSource {
        provenance.append(
          MetadataObservation(
            key: "ResolvedDeviceModel", rawValueString: value,
            provenance: source.provenance))
      }
    }
    provenance.append(
      MetadataObservation(
        key: "ExifMakeModelMirroredFromHostObservedDeviceIdentity",
        rawValueString: capture.metadata.embeddedSourceExif == nil
          && capture.metadata.deviceIdentity == nil
          ? "true" : "false",
        provenance: .applicationGenerated))
    return provenance
  }

  private func existingFinalized(_ uuid: UUID) async throws -> (
    url: URL, hashHex: String, codec: String, settings: String
  )? {
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }),
      let fileName = entry.codecFileName, let expectedHash = entry.fileHashSHA256
    else { return nil }
    guard fileName == "capture.jpg" || fileName == "capture.avif",
      !isSymlink(stagingDirectory(uuid))
    else { throw QueueError.originalUnavailable("invalid staged path") }
    let url = stagingDirectory(uuid).appendingPathComponent(fileName)
    guard
      try await stagedFileValidationWorker.matchesHash(
        file: url, stagingDirectory: stagingDirectory(uuid), expectedHash: expectedHash)
    else { return nil }
    return (url, expectedHash, entry.codec ?? "unknown", entry.encoderSettings ?? "")
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func loadCapture(_ uuid: UUID) throws -> CapturedCapture {
    let dir = stagingDirectory(uuid)
    let source = dir.appendingPathComponent("capture.json")
    guard !isSymlink(dir), !isSymlink(source), FileManager.default.fileExists(atPath: source.path)
    else {
      throw QueueError.missingOriginal(uuid)
    }
    do {
      let capture = try JSONDecoder().decode(CapturedCapture.self, from: Data(contentsOf: source))
      guard capture.uuid == uuid else { throw QueueError.invalidCapture(uuid) }
      return capture
    } catch let error as QueueError { throw error } catch { throw QueueError.invalidCapture(uuid) }
  }

  /// Explicit local export only. Reports include the original serialized
  /// attachments and capture identity; nothing is uploaded by the application.
  public func exportMetadataReport(uuid: UUID, to destination: URL) async throws -> URL {
    guard !saveAsInProgress, !terminationRequested else { throw QueueError.busy }
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }),
      entry.hasMetadataReport == true
    else { throw QueueError.missingOriginal(uuid) }
    _ = try checkedStagingChildren(for: entry)
    let source = stagingDirectory(uuid).appendingPathComponent("metadata-report.json")
    let data = try Data(contentsOf: source)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    saveAsInProgress = true
    defer {
      saveAsInProgress = false
      resumeTerminationWaitersIfIdle()
      Task { self.pumpPendingWork() }
    }
    guard
      try await saveAsWorker.exportIfMatching(
        finalizedFile: source, stagingDirectory: stagingDirectory(uuid),
        expectedHash: hash, to: destination)
    else {
      throw QueueError.originalUnavailable("the metadata report changed before export")
    }
    return destination
  }

  public func retry(uuid: UUID, confirmingPossibleDuplicate: Bool = false) async throws {
    guard !terminationRequested else { throw QueueError.terminating }
    guard inFlightCount < maxInFlight, !saveAsInProgress else { throw QueueError.busy }
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard !entry.shouldDiscardOnTermination else {
      throw QueueError.originalUnavailable("capture deletion is already pending")
    }
    if entry.isPermanentlyUnencodable {
      throw QueueError.originalUnavailable(
        entry.lastError ?? "The saved capture lacks enough verified color metadata to encode.")
    }
    if (entry.stage == .ambiguousImport || entry.stage == .addingToPhotos)
      && !confirmingPossibleDuplicate
    {
      throw QueueError.ambiguousNeedsConfirmation
    }
    guard
      entry.stage != .saved && entry.stage != .savedWithMetadataReport
        && entry.stage != .exportedOriginal
    else {
      throw QueueError.originalUnavailable("capture is already completed")
    }
    let capture = try loadCapture(uuid)
    pendingCaptureIDs.removeAll { $0 == uuid }
    try restoreCaptureToProgress(uuid: uuid)
    try updateJournal(uuid, stage: .encoding, error: nil)
    inFlightCount += 1
    activeCaptures.insert(uuid)
    Task(priority: .utility) { await process(capture) }
  }

  public func sha256Hex(of data: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(data))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Restore safe pre-import work automatically; an interrupted Photos call
  /// is never retried without a deliberate user action.
  public func reconcileOnLaunch() async throws {
    var entries = try readJournal()  // corrupt journal is surfaced; never overwritten
    let previouslyDismissedIDs = Set(
      entries.filter {
        $0.shouldDiscardOnTermination
          || ($0.isProgressDismissed && $0.isRetainedDismissed
            && $0.stage != .saved && $0.stage != .exportedOriginal)
      }.map(\.uuid))
    if !previouslyDismissedIDs.isEmpty {
      for index in entries.indices where previouslyDismissedIDs.contains(entries[index].uuid) {
        entries[index].discardOnTermination = true
        entries[index].updatedAt = Date()
      }
      try writeJournal(entries)
      for uuid in previouslyDismissedIDs {
        try removeStagingDirectoryForTermination(uuid)
      }
      entries.removeAll { $0.shouldDiscardOnTermination }
      try writeJournal(entries)
    }
    try recoverOrphanedSources(entries: &entries)
    for entry in entries {
      if activeCaptures.contains(entry.uuid) { continue }
      if entry.stage == .saved {
        try? FileManager.default.removeItem(at: stagingDirectory(entry.uuid))
      } else if entry.stage == .exportedOriginal {
        try? FileManager.default.removeItem(at: stagingDirectory(entry.uuid))
      } else if entry.isPermanentlyUnencodable
        && entry.stage != .failedUnsupportedColorDescriptor
      {
        try updateJournal(
          entry.uuid, stage: .failedUnsupportedColorDescriptor,
          error: CapturedCapture.SnapshotError.unsupportedColorDescriptor.localizedDescription)
      } else if entry.stage == .addingToPhotos {
        try updateJournal(
          entry.uuid, stage: .ambiguousImport,
          error: "Previous Photos request may have completed; confirm before retrying.")
      } else if [.capturing, .capturedLocally, .encoding, .validating].contains(entry.stage),
        !pendingCaptureIDs.contains(entry.uuid)
      {
        pendingCaptureIDs.append(entry.uuid)
      }
    }
    pumpPendingWork()
    NotificationCenter.default.post(name: Self.changedNotification, object: nil)
  }

  private func pumpPendingWork() {
    guard !terminationRequested else {
      resumeTerminationWaitersIfIdle()
      return
    }
    guard inFlightCount < maxInFlight, !saveAsInProgress else { return }
    while !pendingCaptureIDs.isEmpty {
      let uuid = pendingCaptureIDs.removeFirst()
      if activeCaptures.contains(uuid) { continue }
      do {
        guard let latest = try readJournal().first(where: { $0.uuid == uuid }),
          !latest.shouldDiscardOnTermination,
          [.capturing, .capturedLocally, .encoding, .validating].contains(latest.stage)
        else { continue }
        let capture = try loadCapture(uuid)
        try updateJournal(uuid, stage: .encoding)
        inFlightCount += 1
        activeCaptures.insert(uuid)
        Task(priority: .utility) { await process(capture) }
        return
      } catch {
        try? updateJournal(uuid, stage: .failedEncoding, error: error.localizedDescription)
      }
    }
  }

  private func recoverOrphanedSources(entries: inout [JournalEntry]) throws {
    try ensureDirectoryDurable(stagingRoot, rejectSymlinkAtTarget: true)
    let indexed = Set(entries.map(\.uuid))
    let folders = try FileManager.default.contentsOfDirectory(
      at: stagingRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    var changed = false
    for folder in folders {
      guard !isSymlink(folder),
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true,
        let uuid = UUID(uuidString: folder.lastPathComponent), !indexed.contains(uuid)
      else { continue }
      let file = folder.appendingPathComponent("capture.json")
      guard !isSymlink(file), FileManager.default.fileExists(atPath: file.path) else { continue }
      do {
        let capture = try JSONDecoder().decode(CapturedCapture.self, from: Data(contentsOf: file))
        guard capture.uuid == uuid else { continue }
        if capture.hasMetadataReport {
          try durableAtomicWrite(
            capture.metadataReportData(), to: folder.appendingPathComponent("metadata-report.json"))
        }
        entries.append(
          JournalEntry(
            uuid: uuid, stage: .capturedLocally, stagingPath: folder.path,
            createdAt: Date(), updatedAt: Date(),
            lastError: "Recovered staged capture without a journal record.",
            hasMetadataReport: capture.hasMetadataReport))
        changed = true
      } catch {
        // Leave malformed orphan data untouched and visibly report it.
        NotificationCenter.default.post(
          name: Self.changedNotification, object: nil,
          userInfo: ["error": "Unindexed staged data at \(folder.path) could not be decoded."])
      }
    }
    guard entries.count <= journalMaxEntries else { throw QueueError.busy }
    if changed { try writeJournal(entries) }
  }

  /// Exports the exact verified finalized file. If interrupted before file
  /// finalization, it resumes finalization from the retained source first.
  public func saveOriginal(uuid: UUID, to destination: URL) async throws -> URL {
    guard !terminationRequested else { throw QueueError.terminating }
    guard !saveAsInProgress else { throw QueueError.busy }
    saveAsInProgress = true
    defer {
      saveAsInProgress = false
      resumeTerminationWaitersIfIdle()
      Task { self.pumpPendingWork() }
    }
    guard let entry = try readJournal().first(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard !entry.shouldDiscardOnTermination else {
      throw QueueError.originalUnavailable("capture deletion is already pending")
    }
    if entry.isPermanentlyUnencodable {
      throw QueueError.originalUnavailable(
        entry.lastError ?? "The saved capture lacks enough verified color metadata to encode.")
    }
    let wasActive = activeCaptures.contains(uuid)
    if !wasActive { activeCaptures.insert(uuid) }
    let pendingIndex = pendingCaptureIDs.firstIndex(of: uuid)
    pendingCaptureIDs.removeAll { $0 == uuid }
    defer {
      if !wasActive {
        activeCaptures.remove(uuid)
        if let pendingIndex,
          let latest = try? readJournal().first(where: { $0.uuid == uuid }),
          [.capturing, .capturedLocally, .encoding, .validating].contains(latest.stage)
        {
          // A failed explicit export must not strand a waiting capture until
          // relaunch. Successful exports have a terminal journal state.
          pendingCaptureIDs.insert(uuid, at: min(pendingIndex, pendingCaptureIDs.count))
        }
      }
    }
    var finalized: (url: URL, hashHex: String)
    var copiedFinalizedFile = false
    if let fileName = entry.codecFileName, let expectedHash = entry.fileHashSHA256 {
      guard fileName == "capture.jpg" || fileName == "capture.avif" else {
        throw QueueError.originalUnavailable("invalid staged path")
      }
      let directory = stagingDirectory(uuid)
      let source = directory.appendingPathComponent(fileName)
      copiedFinalizedFile = try await saveAsWorker.exportIfMatching(
        finalizedFile: source, stagingDirectory: directory,
        expectedHash: expectedHash, to: destination)
      if copiedFinalizedFile {
        finalized = (source, expectedHash)
      } else if wasActive {
        throw QueueError.originalUnavailable(
          "the finalized file did not match its recorded hash while its Photos request was active")
      } else {
        let capture = try loadCapture(uuid)
        let encoded = try await finalize(capture)
        try updateJournal(
          uuid, stage: entry.stage, fileHash: encoded.hashHex,
          codec: encoded.codec, settings: encoded.settings, fileName: encoded.url.lastPathComponent)
        finalized = (encoded.url, encoded.hashHex)
      }
    } else {
      guard !wasActive else {
        throw QueueError.originalUnavailable("the active Photos request has no finalized file")
      }
      let capture = try loadCapture(uuid)
      let encoded = try await finalize(capture)
      try updateJournal(
        uuid, stage: entry.stage, fileHash: encoded.hashHex,
        codec: encoded.codec, settings: encoded.settings, fileName: encoded.url.lastPathComponent)
      finalized = (encoded.url, encoded.hashHex)
    }
    if !copiedFinalizedFile {
      let copied = try await saveAsWorker.exportIfMatching(
        finalizedFile: finalized.url,
        stagingDirectory: stagingDirectory(uuid),
        expectedHash: finalized.hashHex,
        to: destination)
      guard copied else {
        throw QueueError.originalUnavailable("the finalized file changed before export")
      }
    }
    if !wasActive && entry.stage != .savedWithMetadataReport {
      try updateJournal(
        uuid, stage: .exportedOriginal,
        fileHash: finalized.hashHex,
        fileName: finalized.url.lastPathComponent, error: entry.lastError)
      try? FileManager.default.removeItem(at: stagingDirectory(uuid))
    }
    return destination
  }

  /// Hide an inactive failed capture without deleting its immutable source or finalized file.
  public func dismissFailedCaptureFromProgress(uuid: UUID) throws {
    var entries = try readJournal()
    guard let index = entries.firstIndex(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard !activeCaptures.contains(uuid), entries[index].stage.canDismissFromProgress else {
      throw QueueError.originalUnavailable("only inactive failed captures can be dismissed")
    }
    if entries[index].isPermanentlyUnencodable {
      entries[index].stage = .failedUnsupportedColorDescriptor
    }
    entries[index].progressDismissed = true
    entries[index].retainedDismissed = entries[index].stage != .savedWithMetadataReport
    entries[index].updatedAt = Date()
    try writeJournal(entries)
  }

  private func restoreCaptureToProgress(uuid: UUID) throws {
    var entries = try readJournal()
    guard let index = entries.firstIndex(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    entries[index].progressDismissed = false
    entries[index].retainedDismissed = false
    try writeJournal(entries)
  }

  /// Hide a retained capture from the active recovery list without deleting it.
  public func dismissRetainedCapture(uuid: UUID) throws {
    try setRetainedCaptureDismissed(uuid: uuid, dismissed: true)
  }

  /// Bring a previously hidden retained capture back into the recovery list.
  public func restoreRetainedCapture(uuid: UUID) throws {
    try setRetainedCaptureDismissed(uuid: uuid, dismissed: false)
  }

  private func setRetainedCaptureDismissed(uuid: UUID, dismissed: Bool) throws {
    var entries = try readJournal()
    guard let index = entries.firstIndex(where: { $0.uuid == uuid }) else {
      throw QueueError.missingOriginal(uuid)
    }
    guard entries[index].isProgressDismissed, entries[index].stage != .exportedOriginal else {
      throw QueueError.originalUnavailable("capture is not in retained recovery")
    }
    guard !entries[index].shouldDiscardOnTermination else {
      throw QueueError.originalUnavailable("capture deletion is already pending")
    }
    entries[index].retainedDismissed = dismissed
    entries[index].updatedAt = Date()
    try writeJournal(entries)
  }

  public func suggestedOriginalFileName(uuid: UUID) throws -> String {
    let ext: String
    if let entry = try readJournal().first(where: { $0.uuid == uuid }),
      let fileName = entry.codecFileName
    {
      guard fileName == "capture.jpg" || fileName == "capture.avif" else {
        throw QueueError.originalUnavailable("invalid staged path")
      }
      ext = URL(fileURLWithPath: fileName).pathExtension
    } else {
      let capture = try loadCapture(uuid)
      switch capture.payload {
      case .jpegBytes: ext = "jpg"
      case .planes: ext = "avif"
      }
    }
    return "capture-\(uuid.uuidString).\(ext)"
  }
}

/// Current app version for provenance records.
enum AppVersion {
  static let current = "0.1.0"
}
