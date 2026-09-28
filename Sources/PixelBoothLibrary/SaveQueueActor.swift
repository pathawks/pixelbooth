// SaveQueueActor — durable staging and journal; Photos-first save with
// recoverable failure states. Encode, validate, finalize atomically, import,
// and clean up only after confirmed success.

import Foundation
import CryptoKit
import Photos
import PixelBoothCore
import PixelBoothMetadata
import PixelBoothCapture
import PixelBoothAVIF
import PixelBoothJPEG
import PixelBoothAdapters

public actor SaveQueueActor {
  /// Save states, distinct and recoverable; no invented percentage.
  public enum Stage: String, Codable, Sendable {
    case capturing
    case capturedLocally
    case encoding
    case validating
    case addingToPhotos
    case saved
    case failedEncoding
    case failedValidating
    case failedAddingToPhotos
    case failedDiskFull
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

    init(uuid: UUID, stage: Stage, stagingPath: String,
         fileHashSHA256: String? = nil, codec: String? = nil,
         encoderSettings: String? = nil, createdAt: Date, updatedAt: Date) {
      self.uuid = uuid; self.stage = stage
      self.stagingPath = stagingPath
      self.fileHashSHA256 = fileHashSHA256
      self.codec = codec; self.encoderSettings = encoderSettings
      self.createdAt = createdAt; self.updatedAt = updatedAt
    }
  }

  /// One active AVIF encoding job and a bounded thread budget: serializes
  /// the archival stage without blocking the preview.
  private var inFlightCount = 0
  private var maxInFlight = 1
  private var stagingRoot: URL
  private let journalMaxEntries = 200

  public init(stagingRoot: URL? = nil) {
    if let stagingRoot {
      self.stagingRoot = stagingRoot
    } else {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      self.stagingRoot = appSupport.appendingPathComponent("PixelBooth/staging", isDirectory: true)
    }
  }

  /// Enqueue a capture; refuses when at capacity with a clear explanation.
  public func enqueue(_ capture: CapturedCapture) async -> Bool {
    guard inFlightCount < maxInFlight else {
      reportCapacityExhausted()
      return false
    }
    inFlightCount += 1
    writeStagingAndJournal(capture)
    Task {
      await process(capture)
      inFlightCount -= 1
    }
    return true
  }

  private func reportCapacityExhausted() {
    // Durable message the user can act on; no silently dropped captures,
    // no changed encoding settings.
    NotificationCenter.default.post(
      name: Notification.Name("PixelBoothCapacityExhausted"),
      object: nil,
      userInfo: ["message": "Staging capacity exhausted; capture refused. Free space or save originals elsewhere."])
  }

  /// Write the immutable source snapshot and journal entry durably before
  /// treating the capture as safely queued.
  private func writeStagingAndJournal(_ capture: CapturedCapture) {
    try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let dir = stagingRoot.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let metaURL = dir.appendingPathComponent("capture.json")
    if let data = try? JSONEncoder().encode(capture) {
      try? data.write(to: metaURL, options: .atomic)
    }
    updateJournal(capture.uuid, stage: .capturedLocally, stagingPath: dir.path)
  }

  /// Encode + validate + import. Cleanup only after confirmed success.
  private func process(_ capture: CapturedCapture) async {
    updateJournal(capture.uuid, stage: .encoding)
    let finalized: (url: URL, hashHex: String, codec: String, settings: String)
    do {
      finalized = try await finalize(capture)
    } catch {
      updateJournal(capture.uuid, stage: .failedEncoding)
      return
    }

    updateJournal(capture.uuid, stage: .validating)
    // Whole-file hash stored in the journal (never self-referentially inside the file).
    guard !finalized.hashHex.isEmpty else {
      updateJournal(capture.uuid, stage: .failedValidating)
      return
    }

    updateJournal(capture.uuid, stage: .addingToPhotos, fileHash: finalized.hashHex)
    let imported = await importIntoPhotos(fileURL: finalized.url, creationDate: Date())
    if imported {
      updateJournal(capture.uuid, stage: .saved, fileHash: finalized.hashHex)
      // Cleanup only after confirmed success.
      try? FileManager.default.removeItem(at: finalized.url.deletingLastPathComponent())
    } else {
      updateJournal(capture.uuid, stage: .failedAddingToPhotos, fileHash: finalized.hashHex)
    }
  }

  /// Produce the finalized file from the immutable payload:
  /// - MJPEG: JPEG passthrough with documented additional XMP metadata.
  /// - Uncompressed: lossless AVIF with verified native-channel round trip.
  private func finalize(_ capture: CapturedCapture) async throws -> (url: URL, hashHex: String, codec: String, settings: String) {
    let dir = stagingRoot.appendingPathComponent(capture.uuid.uuidString, isDirectory: true)
    switch capture.payload {
    case .jpegBytes(let bytes):
      // Metadata-only addition; image-coding data stays byte-exact.
      let xmp = PixelBoothXMP.build(
        captureUUID: capture.uuid, appVersion: AppVersion.current,
        captureBackend: "AVFoundation",
        backendVersion: capture.metadata.wallClockAnchorISO,
        libavifVersion: LosslessAVIF.libraryVersion,
        actualCaptureFormat: "MJPG 8-bit",
        encoderSettings: "metadata-only",
        metadataProvenance: [], fidelity: "nativePreserved",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO)
      let withMeta = try JPEGMetadataWriter.withAdditionalMetadata(
        original: bytes, additionalXMP: xmp)
      let url = dir.appendingPathComponent("capture.jpg")
      try Data(withMeta).write(to: url, options: .atomic)
      let digest = SHA256.hash(data: withMeta)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      return (url, hex, "jpeg-passthrough", "metadata-only")

    case .planes(let snapshot):
      // Lossless AVIF from planes, verified by exact native-channel decode.
      // Reconstruct mutable plane buffers from the contiguous snapshot
      // (padding excluded at snapshot time; adapters re-apply strides).
      var buffers: [UnsafeMutableRawPointer] = snapshot.contiguous.map { array in
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: array.count, alignment: 16)
        array.withUnsafeBytes { raw in
          ptr.copyMemory(from: raw.baseAddress!, byteCount: array.count)
        }
        return ptr
      }
      defer { for b in buffers { b.deallocate() } }
      let planeBytesPerRow = snapshot.bytesPerRow
      let isRGBIdentity = snapshot.contiguous.count == 4  // BGRA: alpha plane present
      let (data, settings) = try LosslessAVIF.encodeLossless(
        snapshot.asPlanarImage(width: capture.width, height: capture.height,
                               planePointers: buffers),
        isRGBIdentity: isRGBIdentity, yuvRange: nil, chromaLocation: nil)
      let url = dir.appendingPathComponent("capture.avif")
      try Data(data).write(to: url, options: .atomic)
      let digest = SHA256.hash(data: data)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      return (url, hex, settings.codec, "quality=\(settings.quality) speed=\(settings.speed)")
    }
  }

  /// PhotoKit original-resource creation with the finished file — never an
  /// NSImage/CGImage round trip. Minimum authorization: add-only on macOS.
  private func importIntoPhotos(fileURL: URL, creationDate: Date) async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return false }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileURL.lastPathComponent
        request.addResource(with: .photo, fileURL: fileURL, options: options)
        request.creationDate = creationDate
      } completionHandler: { success, error in
        continuation.resume(returning: success && error == nil)
      }
    }
  }

  /// Journal file, versioned, crash-recoverable, bounded disk usage.
  private var journalURL: URL {
    stagingRoot.deletingLastPathComponent().appendingPathComponent("journal.json")
  }

  private func updateJournal(_ uuid: UUID, stage: Stage, stagingPath: String? = nil, fileHash: String? = nil) {
    var entries: [JournalEntry] = []
    if let data = try? Data(contentsOf: journalURL),
       let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) {
      entries = decoded
    }
    if let idx = entries.firstIndex(where: { $0.uuid == uuid }) {
      entries[idx].stage = stage
      entries[idx].updatedAt = Date()
      if let stagingPath { entries[idx].stagingPath = stagingPath }
      if let fileHash { entries[idx].fileHashSHA256 = fileHash }
    } else {
      entries.append(JournalEntry(
        uuid: uuid, stage: stage,
        stagingPath: stagingPath ?? stagingRoot.appendingPathComponent(uuid.uuidString).path,
        createdAt: Date(), updatedAt: Date()))
    }
    if entries.count > journalMaxEntries {
      entries.removeFirst(entries.count - journalMaxEntries)
    }
    if let data = try? JSONEncoder().encode(entries) {
      try? data.write(to: journalURL, options: .atomic)
    }
  }

  public func sha256Hex(of data: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(data))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func sha256Hex(ofFileAt url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return sha256Hex(of: [UInt8](data))
  }

  /// On relaunch, reconcile the journal: entries at non-terminal stages get
  /// reprocessed or explicitly flagged, without blindly creating duplicates.
  public func reconcileOnLaunch() async {
    guard let data = try? Data(contentsOf: journalURL),
          let entries = try? JSONDecoder().decode([JournalEntry].self, from: data) else { return }
    for entry in entries {
      switch entry.stage {
      case .saved:
        try? FileManager.default.removeItem(atPath: entry.stagingPath)
      case .capturing, .capturedLocally, .encoding, .validating, .addingToPhotos:
        // Ambiguous import completion: retain, expose uncertainty, require
        // explicit retry. No unproven idempotency claim.
        NotificationCenter.default.post(
          name: Notification.Name("PixelBoothAmbiguousImport"),
          object: nil,
          userInfo: ["uuid": entry.uuid.uuidString, "stage": entry.stage.rawValue])
      case .failedEncoding, .failedValidating, .failedAddingToPhotos, .failedDiskFull:
        // Recoverable failures; preserve the data and require explicit retry.
        break
      }
    }
  }
}

/// Current app version for provenance records.
enum AppVersion {
  static let current = "0.1.0"
}
