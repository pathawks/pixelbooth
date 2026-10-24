import CryptoKit
import Darwin
import Foundation
import PixelBoothDepth

/// A verified image retained privately until its selected destination succeeds.
public struct PreparedCaptureExport: Sendable {
  public let captureUUID: UUID
  public let finalizedURL: URL
  public let recoveryDirectory: URL
  public let hasMetadataReport: Bool
  public let fileHashSHA256: String

  public var fileExtension: String { finalizedURL.pathExtension }
}

/// One-shot CLI destination with a per-capture journal and no Photos operations.
/// A capacity lock coordinates independent CLI processes without sharing the
/// GUI journal. Failed or interrupted sources remain available for recovery.
public actor StandaloneCaptureExporter {
  public enum ExportError: Error, LocalizedError, Sendable {
    case busy
    case storage(String)
    case invalidPreparedCapture
    case extensionMismatch(expected: String)

    public var errorDescription: String? {
      switch self {
      case .busy: return "A command-line photograph is already being prepared."
      case .storage(let message): return "Capture export failed: \(message)"
      case .invalidPreparedCapture: return "The prepared photograph is unavailable."
      case .extensionMismatch(let expected):
        return "The filename extension must match the preserved image format (.\(expected))."
      }
    }
  }

  private struct Journal: Codable {
    var version = 1
    let captureUUID: UUID
    var stage: String
    let createdAt: Date
    var updatedAt: Date
    let reservationBytes: UInt64
    let hasMetadataReport: Bool
    let sourceHashSHA256: String
    var metadataReportHashSHA256: String?
    var finalizedFileName: String?
    var fileHashSHA256: String?
    var codec: String?
    var encoderSettings: String?
    var destination: String?
    var error: String?
  }

  public private(set) var recoveryDirectory: URL?
  private let stagingRoot: URL
  private let maximumStagedBytes: UInt64
  private let finalizer: CaptureImageFinalizer
  private let exportWorker = SaveAsWorker()
  private var journal: Journal?
  private var working = false
  private var captureLock: Int32?

  public init(
    stagingRoot: URL? = nil,
    maximumStagedBytes: UInt64 = 512 * 1024 * 1024,
    configurationURL: URL? = nil, modelURL: URL? = nil,
    disparityEstimator: (@Sendable ([UInt8]) async throws -> RelativeDisparityMap)? = nil
  ) {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    self.stagingRoot =
      stagingRoot
      ?? support.appendingPathComponent("PixelBoothCLI/staging", isDirectory: true)
    self.maximumStagedBytes = maximumStagedBytes
    self.finalizer = CaptureImageFinalizer(
      disparityEstimator: disparityEstimator, configurationURL: configurationURL, modelURL: modelURL
    )
  }

  deinit {
    if let captureLock { Darwin.close(captureLock) }
  }

  /// Durably retain the immutable source and metadata before starting encoding.
  public func prepare(_ capture: CapturedCapture) async throws -> PreparedCaptureExport {
    guard !working, journal == nil else { throw ExportError.busy }
    working = true
    defer { working = false }
    do {
      try Task.checkCancellation()
      let source = try JSONEncoder().encode(capture)
      let reservation = try CaptureStagingCapacity.reservation(
        for: capture, encodedSourceBytes: source.count)
      let report = capture.hasMetadataReport ? try capture.metadataReportData() : nil
      try withCapacityLock {
        let (count, used) = try reservedCapacity()
        guard count < 200, used <= maximumStagedBytes,
          reservation <= maximumStagedBytes - used
        else { throw SaveQueueActor.QueueError.capacityExceeded }
        let directory = stagingRoot.appendingPathComponent(
          capture.uuid.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
          throw ExportError.storage("capture UUID already has retained data")
        }
        try ensureDirectory(directory, rejectSymlink: true)
        try acquireCaptureLock(in: directory)
        recoveryDirectory = directory
        journal = Journal(
          captureUUID: capture.uuid, stage: "capturing", createdAt: Date(), updatedAt: Date(),
          reservationBytes: reservation, hasMetadataReport: capture.hasMetadataReport,
          sourceHashSHA256: hash(source))
        journal?.metadataReportHashSHA256 = report.map(hash)
        try persistJournal()
        try durableWrite(source, to: directory.appendingPathComponent("capture.json"))
        if let report {
          try durableWrite(report, to: directory.appendingPathComponent("metadata-report.json"))
        }
        try updateStage("capturedLocally")
      }
      return try await finalizeRetained(capture)
    } catch {
      try? updateStage("failed", error: error.localizedDescription)
      releaseCaptureLock()
      throw error
    }
  }

  /// Retry a retained invocation without opening a camera. Source integrity is
  /// checked before decoding; a validated final file is reused only when its
  /// recorded digest matches. Conflicting evidence is retained, never replaced.
  public func resume(recoveryDirectory directory: URL) async throws -> PreparedCaptureExport {
    guard !working, journal == nil else { throw ExportError.busy }
    working = true
    defer { working = false }
    do {
      try Task.checkCancellation()
      let standardized = directory.standardizedFileURL
      guard standardized.deletingLastPathComponent() == stagingRoot.standardizedFileURL,
        let uuid = UUID(uuidString: standardized.lastPathComponent), !isSymlink(standardized)
      else {
        throw ExportError.storage("the recovery directory must be a capture UUID under staging")
      }
      let capture = try withCapacityLock {
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ExportError.storage("the retained capture directory is unavailable")
        }
        try acquireCaptureLock(in: standardized)
        let stored = try JSONDecoder().decode(
          Journal.self,
          from: readBounded(standardized.appendingPathComponent("journal.json"), maximum: 1_048_576)
        )
        let validStages: Set<String> = [
          "capturing", "capturedLocally", "encoding", "validating", "validated", "saving", "failed",
          "saved", "savedWithMetadataReport",
        ]
        guard stored.version == 1, stored.captureUUID == uuid, validStages.contains(stored.stage),
          stored.reservationBytes <= maximumStagedBytes,
          validDigest(stored.sourceHashSHA256)
        else {
          throw ExportError.storage("invalid CLI recovery journal identity, version or state")
        }
        let source = try readBounded(
          standardized.appendingPathComponent("capture.json"), maximum: maximumStagedBytes)
        guard hash(source) == stored.sourceHashSHA256 else {
          throw ExportError.storage(
            "the retained source failed its integrity check; evidence was retained")
        }
        let capture = try JSONDecoder().decode(CapturedCapture.self, from: source)
        guard capture.uuid == uuid, capture.hasMetadataReport == stored.hasMetadataReport else {
          throw ExportError.storage("the retained source does not match its journal")
        }
        let expectedReservation = try CaptureStagingCapacity.reservation(
          for: capture, encodedSourceBytes: source.count)
        guard stored.reservationBytes == expectedReservation else {
          throw ExportError.storage("the retained source does not match its storage reservation")
        }
        let (_, used) = try reservedCapacity()
        guard used <= maximumStagedBytes else { throw SaveQueueActor.QueueError.capacityExceeded }
        let expectedName: String
        switch capture.payload {
        case .jpegBytes: expectedName = "capture.jpg"
        case .planes: expectedName = "capture.avif"
        }
        guard stored.finalizedFileName == nil || stored.finalizedFileName == expectedName else {
          throw ExportError.storage("the retained image format does not match its source")
        }
        recoveryDirectory = standardized
        journal = stored
        if capture.hasMetadataReport {
          guard let expectedReportHash = stored.metadataReportHashSHA256,
            validDigest(expectedReportHash)
          else {
            throw ExportError.storage("the retained metadata report has no valid integrity record")
          }
          let reportURL = standardized.appendingPathComponent("metadata-report.json")
          if FileManager.default.fileExists(atPath: reportURL.path) {
            guard try hashFile(reportURL, maximum: maximumStagedBytes) == expectedReportHash else {
              throw ExportError.storage("the retained metadata report failed its integrity check")
            }
          } else {
            let report = try capture.metadataReportData()
            try durableWrite(report, to: reportURL, replaceExisting: false)
            journal?.metadataReportHashSHA256 = hash(report)
          }
        } else if stored.metadataReportHashSHA256 != nil {
          throw ExportError.storage("the metadata report does not match the retained source")
        }
        return capture
      }
      try Task.checkCancellation()
      if let name = journal?.finalizedFileName {
        guard ["capture.jpg", "capture.avif"].contains(name),
          let expected = journal?.fileHashSHA256, validDigest(expected)
        else { throw ExportError.storage("invalid finalized image identity in recovery journal") }
        let file = standardized.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
          guard try hashFile(file, maximum: maximumStagedBytes) == expected else {
            throw ExportError.storage(
              "the finalized image failed its integrity check; evidence was retained")
          }
          try updateStage("validated")
          return PreparedCaptureExport(
            captureUUID: uuid, finalizedURL: file, recoveryDirectory: standardized,
            hasMetadataReport: capture.hasMetadataReport, fileHashSHA256: expected)
        }
      } else if journal?.fileHashSHA256 != nil {
        throw ExportError.storage("incomplete finalized image identity in recovery journal")
      }
      return try await finalizeRetained(capture)
    } catch {
      try? updateStage("failed", error: error.localizedDescription)
      releaseCaptureLock()
      throw error
    }
  }

  /// Publish the exact finalized bytes atomically, refusing an existing pathname.
  /// Completion is journaled before ordinary staging is removed.
  public func publish(_ prepared: PreparedCaptureExport, to destination: URL) async throws -> URL {
    guard !working else { throw ExportError.busy }
    try requirePrepared(prepared)
    working = true
    defer { working = false }
    do {
      try Task.checkCancellation()
      try requireExternalDestination(destination)
      let suppliedExtension = destination.pathExtension.lowercased()
      let allowed = prepared.fileExtension == "jpg" ? ["jpg", "jpeg"] : ["avif"]
      guard suppliedExtension.isEmpty || allowed.contains(suppliedExtension) else {
        throw ExportError.extensionMismatch(expected: prepared.fileExtension)
      }
      journal?.destination = destination.path
      try updateStage("saving")
      guard let hash = journal?.fileHashSHA256,
        try await exportWorker.exportIfMatching(
          finalizedFile: prepared.finalizedURL, stagingDirectory: prepared.recoveryDirectory,
          expectedHash: hash, to: destination)
      else { throw ExportError.storage("the finalized file failed its integrity check") }
      try complete(prepared, destination: destination.path)
      return destination
    } catch {
      try? updateStage("failed", error: error.localizedDescription)
      throw error
    }
  }

  /// Call only after every base64 byte and its final newline reached stdout.
  public func completeStandardOutput(_ prepared: PreparedCaptureExport) throws {
    guard !working else { throw ExportError.busy }
    try requirePrepared(prepared)
    try complete(prepared, destination: "stdout:base64")
  }

  /// Record a destination failure while retaining the source and final image.
  public func recordFailure(_ prepared: PreparedCaptureExport, message: String) throws {
    guard !working else { throw ExportError.busy }
    try requirePrepared(prepared)
    defer { releaseCaptureLock() }
    try updateStage("failed", error: message)
  }

  private func requirePrepared(_ prepared: PreparedCaptureExport) throws {
    guard captureLock != nil, journal?.captureUUID == prepared.captureUUID,
      journal?.finalizedFileName == prepared.finalizedURL.lastPathComponent,
      recoveryDirectory == prepared.recoveryDirectory,
      prepared.finalizedURL.deletingLastPathComponent() == prepared.recoveryDirectory,
      !isSymlink(prepared.recoveryDirectory), !isSymlink(prepared.finalizedURL)
    else { throw ExportError.invalidPreparedCapture }
  }

  private func complete(_ prepared: PreparedCaptureExport, destination: String) throws {
    journal?.destination = destination
    try updateStage(prepared.hasMetadataReport ? "savedWithMetadataReport" : "saved")
    if !prepared.hasMetadataReport {
      try withCapacityLock {
        try FileManager.default.removeItem(at: prepared.recoveryDirectory)
        try synchronizeDirectory(stagingRoot)
      }
      recoveryDirectory = nil
      journal = nil
    }
    releaseCaptureLock()
  }

  private func finalizeRetained(_ capture: CapturedCapture) async throws -> PreparedCaptureExport {
    try Task.checkCancellation()
    guard let directory = recoveryDirectory else { throw ExportError.invalidPreparedCapture }
    for name in ["capture.jpg", "capture.avif"] {
      guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
      else {
        throw ExportError.storage(
          "an unverified finalized image already exists; evidence was retained")
      }
    }
    try updateStage("encoding")
    let image = try await finalizer.finalize(capture)
    try Task.checkCancellation()
    let output = directory.appendingPathComponent(image.fileName)
    journal?.finalizedFileName = image.fileName
    journal?.fileHashSHA256 = image.hashHex
    journal?.codec = image.codec
    journal?.encoderSettings = image.settings
    // Commit the expected output identity before its atomic publication. A
    // crash on either side can then regenerate an absent file or verify and
    // reuse the complete file without treating it as untracked evidence.
    try updateStage("validating")
    try durableWrite(image.data, to: output, replaceExisting: false)
    try updateStage("validated")
    return PreparedCaptureExport(
      captureUUID: capture.uuid, finalizedURL: output, recoveryDirectory: directory,
      hasMetadataReport: capture.hasMetadataReport, fileHashSHA256: image.hashHex)
  }

  private func requireExternalDestination(_ destination: URL) throws {
    guard destination.isFileURL else {
      throw ExportError.storage("the destination must be a file path")
    }
    let lexicalContainment = destination.path.split(separator: "/").starts(
      with: stagingRoot.path.split(separator: "/"))
    let resolvedContainment = try hasStagingAncestor(destination)
    guard !lexicalContainment, !resolvedContainment else {
      throw ExportError.storage("the output destination must be outside CLI recovery staging")
    }
  }

  /// Follow the nearest existing directory through the filesystem, then walk
  /// its physical parents by descriptor. Device/inode identity handles absent
  /// output leaves, symlink parents, /tmp aliases and case-insensitive volumes.
  private func hasStagingAncestor(_ url: URL) throws -> Bool {
    let rootDescriptor = Darwin.open(stagingRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard rootDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(rootDescriptor) }
    var rootStatus = stat()
    guard Darwin.fstat(rootDescriptor, &rootStatus) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var ancestor = url
    var descriptor: Int32
    while true {
      descriptor = Darwin.open(ancestor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
      if descriptor >= 0 { break }
      guard errno == ENOENT || errno == ENOTDIR else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard !isSymlink(ancestor) else {
        throw ExportError.storage("the destination contains an unresolved symbolic link")
      }
      let parent = ancestor.deletingLastPathComponent()
      guard parent.path != ancestor.path else {
        throw ExportError.storage("the destination directory cannot be resolved")
      }
      ancestor = parent
    }
    defer { Darwin.close(descriptor) }
    while true {
      var status = stat()
      guard Darwin.fstat(descriptor, &status) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if status.st_dev == rootStatus.st_dev, status.st_ino == rootStatus.st_ino { return true }
      let parent = Darwin.openat(descriptor, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      var parentStatus = stat()
      guard Darwin.fstat(parent, &parentStatus) == 0 else {
        Darwin.close(parent)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if parentStatus.st_dev == status.st_dev, parentStatus.st_ino == status.st_ino {
        Darwin.close(parent)
        return false
      }
      Darwin.close(descriptor)
      descriptor = parent
    }
  }

  private func updateStage(_ stage: String, error: String? = nil) throws {
    guard journal != nil else { return }
    journal?.stage = stage
    journal?.updatedAt = Date()
    journal?.error = error
    try persistJournal()
  }

  private func persistJournal() throws {
    guard let journal, let directory = recoveryDirectory else {
      throw ExportError.invalidPreparedCapture
    }
    try durableWrite(
      try JSONEncoder().encode(journal), to: directory.appendingPathComponent("journal.json"))
  }

  /// Admission is the only operation shared across CLI processes. Each source
  /// and journal otherwise belongs to its UUID directory.
  private func withCapacityLock<Result>(_ operation: () throws -> Result) throws -> Result {
    try ensureDirectory(stagingRoot, rejectSymlink: true)
    let lockURL = stagingRoot.appendingPathComponent(".capacity.lock")
    let descriptor = Darwin.open(
      lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw ExportError.storage("the CLI capacity lock is not a regular file")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw ExportError.busy }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
  }

  private func reservedCapacity() throws -> (Int, UInt64) {
    let directories = try FileManager.default.contentsOfDirectory(
      at: stagingRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    var count = 0
    var used: UInt64 = 0
    for directory in directories where directory.lastPathComponent != ".capacity.lock" {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true,
        UUID(uuidString: directory.lastPathComponent) != nil
      else { throw ExportError.storage("unexpected item in the CLI recovery directory") }
      count += 1
      var bytes: UInt64 = 0
      let files = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
      while let file = files?.nextObject() as? URL {
        let fileValues = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard fileValues.isSymbolicLink != true else {
          throw ExportError.storage("symbolic link in the CLI recovery directory")
        }
        let (next, overflow) = bytes.addingReportingOverflow(
          UInt64(max(0, fileValues.fileSize ?? 0)))
        guard !overflow else { throw SaveQueueActor.QueueError.capacityExceeded }
        bytes = next
      }
      let journalURL = directory.appendingPathComponent("journal.json")
      if FileManager.default.fileExists(atPath: journalURL.path) {
        let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else {
          throw ExportError.storage("invalid CLI recovery journal size")
        }
        let stored = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard stored.version == 1, stored.captureUUID.uuidString == directory.lastPathComponent
        else {
          throw ExportError.storage("invalid CLI recovery journal identity or version")
        }
        bytes = max(bytes, stored.reservationBytes)
      }
      let (next, overflow) = used.addingReportingOverflow(bytes)
      guard !overflow else { throw SaveQueueActor.QueueError.capacityExceeded }
      used = next
    }
    return (count, used)
  }

  private func durableWrite(_ data: Data, to destination: URL, replaceExisting: Bool = true) throws
  {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try handle.close()
      let renamed =
        replaceExisting
        ? Darwin.rename(temporary.path, destination.path)
        : Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
      guard renamed == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try synchronizeDirectory(directory)
      let committed = try FileHandle(forReadingFrom: destination)
      defer { try? committed.close() }
      guard Darwin.fcntl(committed.fileDescriptor, F_FULLFSYNC) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private func ensureDirectory(_ directory: URL, rejectSymlink: Bool = false) throws {
    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values?.isSymbolicLink == true {
      guard !rejectSymlink else { throw ExportError.storage("recovery path is a symbolic link") }
      try synchronizeDirectory(directory)
      return
    }
    if values?.isDirectory == true { return }
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else {
      throw ExportError.storage("directory is unavailable")
    }
    try ensureDirectory(parent)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      let check = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard check.isDirectory == true, check.isSymbolicLink != true else { throw error }
    }
    try synchronizeDirectory(parent)
    try synchronizeDirectory(directory)
  }

  private func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func acquireCaptureLock(in directory: URL) throws {
    guard captureLock == nil else { throw ExportError.busy }
    let file = directory.appendingPathComponent(".capture.lock")
    let descriptor = Darwin.open(
      file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)
      throw ExportError.storage("the capture lock is not a regular file")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw ExportError.busy
    }
    captureLock = descriptor
  }

  private func releaseCaptureLock() {
    if let captureLock { Darwin.close(captureLock) }
    captureLock = nil
  }

  private func validDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func readBounded(_ url: URL, maximum: UInt64) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0, UInt64(status.st_size) <= maximum
    else { throw ExportError.storage("retained file is not a bounded regular file") }
    var result = Data()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      guard UInt64(chunk.count) <= maximum - UInt64(result.count) else {
        throw ExportError.storage("retained file exceeds the recovery size limit")
      }
      result.append(chunk)
    }
    return result
  }

  private func hashFile(_ url: URL, maximum: UInt64) throws -> String {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0, UInt64(status.st_size) <= maximum
    else { throw ExportError.storage("retained image is not a bounded regular file") }
    var total: UInt64 = 0
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      guard UInt64(chunk.count) <= maximum - total else {
        throw ExportError.storage("retained image exceeds the recovery size limit")
      }
      total += UInt64(chunk.count)
      digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
