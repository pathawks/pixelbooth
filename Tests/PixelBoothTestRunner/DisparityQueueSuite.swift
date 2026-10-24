import Foundation
import ImageIO
import PixelBoothAVIF
import PixelBoothCAvifShim
import PixelBoothCore
import PixelBoothDepth
import PixelBoothJPEG
import PixelBoothLibrary
import PixelBoothMetadata

private enum DisparityQueueAssertion: Error, LocalizedError {
  case failed(String)
  case estimatorFailed

  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    case .estimatorFailed: return "Synthetic disparity estimator failure"
    }
  }
}

private actor DisparityQueueProbe {
  private let failEstimation: Bool
  private let holdFirstImport: Bool
  private let holdFirstEstimate: Bool
  private let successfulImport: Bool
  private var importContinuation: CheckedContinuation<SaveQueueActor.ImportResult, Never>?
  private var estimateContinuation: CheckedContinuation<Void, Never>?
  private var importReleased = false
  private var estimateReleased = false
  private var activeEstimates = 0
  private(set) var maximumActiveEstimates = 0
  private(set) var estimatorInputs: [[UInt8]] = []
  private(set) var importedFiles: [URL] = []
  private(set) var importedBytes: [[UInt8]] = []

  init(
    failEstimation: Bool = false, holdFirstImport: Bool = false,
    holdFirstEstimate: Bool = false, successfulImport: Bool = false
  ) {
    self.failEstimation = failEstimation
    self.holdFirstImport = holdFirstImport
    self.holdFirstEstimate = holdFirstEstimate
    self.successfulImport = successfulImport
  }

  func estimate(_ primary: [UInt8]) async throws -> RelativeDisparityMap {
    estimatorInputs.append(primary)
    activeEstimates += 1
    maximumActiveEstimates = max(maximumActiveEstimates, activeEstimates)
    defer { activeEstimates -= 1 }
    if holdFirstEstimate && estimatorInputs.count == 1 && !estimateReleased {
      await withCheckedContinuation { estimateContinuation = $0 }
    }
    if failEstimation { throw DisparityQueueAssertion.estimatorFailed }
    return try RelativeDisparityMap(width: 2, height: 2, values: [0, 0.25, 0.5, 1])
  }

  func importFile(_ file: URL) async -> SaveQueueActor.ImportResult {
    importedFiles.append(file)
    importedBytes.append((try? [UInt8](Data(contentsOf: file))) ?? [])
    if holdFirstImport && importedFiles.count == 1 && !importReleased {
      return await withCheckedContinuation { importContinuation = $0 }
    }
    return successfulImport
      ? .saved : .failed("Synthetic import failure; finalized original retained")
  }

  func release() {
    importReleased = true
    importContinuation?.resume(returning: .failed("Synthetic import failure"))
    importContinuation = nil
    estimateReleased = true
    estimateContinuation?.resume()
    estimateContinuation = nil
  }
}

private func disparityAVIF(_ requested: Bool?) -> CapturedCapture {
  var capture = CapturedCapture.makeTestCapture(
    fourCC: 0x4e56_3132, width: 4, height: 2,
    payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
  capture.color = CapturedCapture.ColorDescriptor(
    yuvRange: .full, primaries: nil, transfer: nil, matrix: nil,
    chromaLocation: nil, iccProfile: nil)
  capture.metadata.includeEstimatedDisparity = requested
  return capture
}

private func disparityPrimaryMetadata(_ bytes: [UInt8]) throws -> (exif: [UInt8], xmp: [UInt8]) {
  guard let image = avifImageCreateEmpty() else {
    throw DisparityQueueAssertion.failed("Metadata image allocation failed")
  }
  defer { avifImageDestroy(image) }
  guard let decoder = avifDecoderCreate() else {
    throw DisparityQueueAssertion.failed("Metadata decoder allocation failed")
  }
  defer { avifDecoderDestroy(decoder) }
  let status = bytes.withUnsafeBufferPointer { buffer in
    avifDecoderReadMemory(decoder, image, buffer.baseAddress, buffer.count)
  }
  guard status == AVIF_RESULT_OK else {
    throw DisparityQueueAssertion.failed("Cannot read finalized primary metadata")
  }
  func copied(_ data: avifRWData) -> [UInt8] {
    Array(UnsafeBufferPointer(start: data.data, count: data.size))
  }
  return (copied(image.pointee.exif), copied(image.pointee.xmp))
}

private func disparityJPEG(_ requested: Bool?) -> CapturedCapture {
  var capture = CapturedCapture.makeTestCapture(
    fourCC: 0x4d4a_5047, width: 4, height: 4, payload: .jpegBytes(jpegFixture()))
  capture.metadata.includeEstimatedDisparity = requested
  return capture
}

private func waitForDisparityStage(
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
  throw DisparityQueueAssertion.failed("Timed out waiting for \(capture.uuid) at \(stage)")
}

private func stopDisparityQueue(_ queue: SaveQueueActor, _ probe: DisparityQueueProbe) async {
  _ = await queue.beginTermination()
  await probe.release()
  await queue.waitForTerminationWorkToFinish()
}

private func withDisparityQueue(
  probe: DisparityQueueProbe = DisparityQueueProbe(),
  maximumStagedBytes: UInt64 = 512 * 1024 * 1024,
  _ body: (SaveQueueActor, URL, DisparityQueueProbe) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pb-disparity-queue-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let queue = SaveQueueActor(
    stagingRoot: root.appendingPathComponent("staging"),
    importer: { file, _ in await probe.importFile(file) },
    maximumStagedBytes: maximumStagedBytes,
    disparityEstimator: { primary in try await probe.estimate(primary) })
  do {
    try await body(queue, root, probe)
  } catch {
    await stopDisparityQueue(queue, probe)
    throw error
  }
  await stopDisparityQueue(queue, probe)
}

func runDisparityQueueSuite() async {
  suite("DisparityQueue")

  await test("warningWithoutAttachmentEntriesStillSavesImageAndEmbedsReport") {
    let probe = DisparityQueueProbe(successfulImport: true)
    try await withDisparityQueue(probe: probe) { queue, _, _ in
      var capture = disparityAVIF(false)
      let archive = CaptureAttachmentArchive(
        issues: ["delivered.YCbCrMatrix: unavailable; matrix coefficients remain unspecified"])
      capture.metadata.attachmentArchive = archive
      capture.metadata.streamColorObservations = [
        DeliveredColorObservation(
          frameIndex: 1, deviceUniqueID: capture.deviceUniqueID,
          generation: capture.metadata.generation, width: capture.width, height: capture.height,
          fourCC: capture.fourCC, mediaTimeNanos: 1, hostMonotonicNanos: 2,
          observedAtISO: capture.acceptedAtISO,
          pixelBuffer: .init(matrix: "ITU_R_601_4"), formatDescription: .init())
      ]
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .savedWithMetadataReport)
      let directory = URL(fileURLWithPath: entry.stagingPath)
      let original = try [UInt8](Data(contentsOf: directory.appendingPathComponent("capture.avif")))
      let decoded = try LosslessAVIF.decode(encoded: original)
      try requireRecovery(decoded.matrixCoefficients == 2, "unknown matrix never becomes a guess")
      let metadata = try disparityPrimaryMetadata(original)
      let xmp = String(decoding: metadata.xmp, as: UTF8.self)
      let suffix = capture.uuid.uuidString.replacingOccurrences(of: "-", with: "")
      guard let imageMetadata = CGImageMetadataCreateFromXMPData(Data(metadata.xmp) as CFData),
        let historyText = (0..<64).compactMap({ index in
          CGImageMetadataCopyStringValueWithPath(
            imageMetadata, nil, "pbx:Provenance\(index)" as CFString) as String?
        }).first(where: { $0.hasPrefix("StreamColorObservationsV1_\(suffix)=") }),
        let payloadStart = historyText.firstIndex(of: "="),
        historyText.hasSuffix("|hostObserved")
      else { throw DisparityQueueAssertion.failed("Host-observed stream color evidence missing") }
      let historyJSON = String(historyText[historyText.index(after: payloadStart)...])
        .dropLast("|hostObserved".count)
      try requireRecovery(
        try JSONDecoder().decode(
          [DeliveredColorObservation].self, from: Data(historyJSON.utf8))
          == capture.metadata.streamColorObservations,
        "actual stream metadata is preserved in XMP with host-observed attribution")
      func embedded(_ key: String) throws -> Data {
        guard let start = xmp.range(of: "\(key)_\(suffix)="),
          let end = xmp.range(of: "|applicationGenerated", range: start.upperBound..<xmp.endIndex),
          let data = Data(base64Encoded: String(xmp[start.upperBound..<end.lowerBound]))
        else { throw DisparityQueueAssertion.failed("Missing embedded \(key)") }
        return data
      }
      try requireRecovery(
        try JSONDecoder().decode(
          CaptureAttachmentArchive.self, from: embedded("AttachmentArchiveV1")) == archive,
        "an issue-only archive is retained even without attachment entries")
      try requireRecovery(
        try embedded("MetadataReportV1") == capture.metadataReportData(),
        "issue-only metadata report is embedded in the final image")
      try requireRecovery(
        try Data(contentsOf: directory.appendingPathComponent("metadata-report.json"))
          == capture.metadataReportData(), "the matching diagnostic remains durable locally")
      let restored = try JSONDecoder().decode(
        CapturedCapture.self,
        from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
      guard case .planes(let retained) = restored.payload,
        case .planes(let source) = capture.payload
      else { throw DisparityQueueAssertion.failed("Retained native source missing") }
      try requireRecovery(retained == source, "native source is retained after save")
      try await queue.reconcileOnLaunch()
      try requireRecovery(
        await probe.importedBytes.count == 1, "saved warning is not imported again after recovery")
    }
  }

  await test("metadataWarningsSaveImageRetainEvidenceAndExportReport") {
    let probe = DisparityQueueProbe(successfulImport: true)
    try await withDisparityQueue(probe: probe) { queue, root, _ in
      var capture = disparityAVIF(false)
      let payload = try PropertyListSerialization.data(
        fromPropertyList: ["value": Data([0xB5, 0, 0xFF, 3])], format: .binary, options: 0)
      let archive = CaptureAttachmentArchive(
        entries: [
          .init(
            scope: "source.sample[0]", key: "HDR10PlusPerFrameData",
            encoding: "binary-property-list", payload: payload)
        ],
        issues: ["HDR10PlusPerFrameData: original data archived; native rendering support pending"])
      capture.metadata.attachmentArchive = archive
      capture.metadata.hostObservedDeviceMake = "Unknown"
      capture.metadata.hostObservedDeviceModel = "Reported model"
      capture.metadata.usbIdentity = USBDeviceIdentity(
        vendorID: 0x046D, productID: 0x085E, locationID: 0x1234_0000,
        associationMethod: "synthetic checked association")
      capture.metadata.deviceIdentity = DeviceIdentityResolution.resolve(
        manufacturer: "Unknown", model: "Reported model", usb: capture.metadata.usbIdentity)
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .savedWithMetadataReport)
      let directory = URL(fileURLWithPath: entry.stagingPath)
      try requireRecovery(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("capture.json").path),
        "successful import retains source for metadata investigation")
      let original = try [UInt8](Data(contentsOf: directory.appendingPathComponent("capture.avif")))
      let metadata = try disparityPrimaryMetadata(original)
      let xmp = String(decoding: metadata.xmp, as: UTF8.self)
      let marker =
        "AttachmentArchiveV1_\(capture.uuid.uuidString.replacingOccurrences(of: "-", with: ""))="
      guard let start = xmp.range(of: marker),
        let end = xmp.range(of: "|applicationGenerated", range: start.upperBound..<xmp.endIndex),
        let data = Data(base64Encoded: String(xmp[start.upperBound..<end.lowerBound]))
      else { throw DisparityQueueAssertion.failed("Embedded metadata archive missing") }
      let recovered = try JSONDecoder().decode(CaptureAttachmentArchive.self, from: data)
      try requireRecovery(recovered == archive, "every archived metadata byte is inside final AVIF")
      for observation in [
        "USBVendorID=0x046D", "USBProductID=0x085E",
        "ResolvedDeviceMake=Logitech|applicationGenerated",
      ] {
        try requireRecovery(xmp.contains(observation), "USB identity is retained in image XMP")
      }
      let destination = root.appendingPathComponent("exported-metadata.json")
      _ = try await queue.exportMetadataReport(uuid: capture.uuid, to: destination)
      try requireRecovery(
        try Data(contentsOf: destination) == capture.metadataReportData(),
        "report exports exactly and includes capture-specific evidence")
      try await queue.dismissFailedCaptureFromProgress(uuid: capture.uuid)
      try await queue.reconcileOnLaunch()
      try requireRecovery(
        (try await queue.entries()).first?.stage == .savedWithMetadataReport,
        "saved metadata warning survives reconciliation")
      try requireRecovery(
        await probe.importedBytes.count == 1, "reconciliation never reimports a saved warning")
      do {
        try await queue.retry(uuid: capture.uuid)
        throw DisparityQueueAssertion.failed("saved warning reimported")
      } catch is SaveQueueActor.QueueError {}
      try requireRecovery(
        await probe.importedBytes.count == 1, "explicit retry cannot duplicate completed import")
    }
  }

  await test("colorInterpretationFailureIsDurablySavedWithReportBeforeExportFailure") {
    try await withDisparityQueue { queue, _, probe in
      var capture = disparityAVIF(false)
      capture.metadata.colorEncodingFailure = "Synthetic unrecognized transfer function"
      capture.metadata.attachmentArchive = CaptureAttachmentArchive(
        entries: [
          .init(
            scope: "delivered.pixels", key: "UnknownTransfer",
            encoding: "binary-property-list", payload: Data([1, 2, 3]))
        ],
        issues: ["Synthetic unrecognized transfer function"])
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .failedUnsupportedColorDescriptor)
      let directory = URL(fileURLWithPath: entry.stagingPath)
      let restored = try JSONDecoder().decode(
        CapturedCapture.self,
        from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
      try requireRecovery(
        restored.metadata.attachmentArchive == capture.metadata.attachmentArchive,
        "unsupported interpretation never loses original attachment evidence")
      guard case .planes(let retained) = restored.payload,
        case .planes(let original) = capture.payload
      else {
        throw DisparityQueueAssertion.failed("Retained native planes missing")
      }
      try requireRecovery(retained == original, "native image remains durably retained")
      try requireRecovery(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("metadata-report.json").path),
        "specific report exists before failed final encoding")
      try requireRecovery(
        !entry.isPermanentlyUnencodable, "retained report can be retried by a future implementation"
      )
      try requireRecovery(
        await probe.importedBytes.isEmpty,
        "uninterpretable image is not silently relabeled for Photos")
    }
  }

  await test("USBManufacturerPreferenceReachesGeneratedAVIFExif") {
    try await withDisparityQueue { queue, _, _ in
      for make in ["API manufacturer", "Unknown"] {
        var capture = disparityAVIF(false)
        capture.metadata.hostObservedDeviceMake = make
        capture.metadata.usbIdentity = USBDeviceIdentity(
          vendorID: 0x046D, productID: 0x085E, locationID: 1)
        capture.metadata.deviceIdentity = DeviceIdentityResolution.resolve(
          manufacturer: make, model: "Fixture Camera",
          usb: capture.metadata.usbIdentity)
        try await queue.enqueue(capture)
        let entry = try await waitForDisparityStage(queue, capture, .failedAddingToPhotos)
        let bytes = try [UInt8](
          Data(
            contentsOf: URL(fileURLWithPath: entry.stagingPath).appendingPathComponent(
              "capture.avif")))
        let metadata = try disparityPrimaryMetadata(bytes)
        let text = String(decoding: metadata.exif, as: UTF8.self)
        try requireRecovery(
          text.contains(make == "Unknown" ? "Logitech" : "API manufacturer"),
          "generated Exif follows API-first then VID lookup priority")
      }
    }
  }

  await test("unknownManufacturerIsOmittedFromFinalizedJPEGAndAVIFExif") {
    try await withDisparityQueue { queue, _, _ in
      for jpeg in [false, true] {
        var capture = jpeg ? disparityJPEG(false) : disparityAVIF(false)
        if jpeg {
          // ImageIO itself may emit a minimal Exif block even without our
          // fixture metadata. Remove it to exercise generated-Exif insertion;
          // production must preserve any camera-supplied block instead.
          var structure = try JPEGParser.parse(jpegFixture(includeMetadata: false))
          if let sourceExif = structure.exifSegment {
            structure.segments.removeAll { $0 == sourceExif }
          }
          let bytes = structure.reconstructedBytes()
          try requireRecovery(
            try JPEGParser.parse(bytes).exifSegment == nil,
            "fixture has no source Exif")
          capture.payload = .jpegBytes(bytes)
        } else {
          capture.color = CapturedCapture.ColorDescriptor(
            yuvRange: .full, primaries: 1, transfer: 1, matrix: 1,
            chromaLocation: .left, iccProfile: nil)
        }
        capture.metadata.hostObservedDeviceMake = "Unknown"
        capture.metadata.hostObservedDeviceModel = "Fixture Camera"
        let restored = try JSONDecoder().decode(
          CapturedCapture.self, from: JSONEncoder().encode(capture))
        try await queue.enqueue(restored)
        let entry = try await waitForDisparityStage(queue, restored, .failedAddingToPhotos)
        let file = URL(fileURLWithPath: entry.stagingPath)
          .appendingPathComponent(jpeg ? "capture.jpg" : "capture.avif")
        let data = try Data(contentsOf: file)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
          throw DisparityQueueAssertion.failed("Finalized image unreadable: \(file.pathExtension)")
        }
        guard let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        else {
          throw DisparityQueueAssertion.failed(
            "Finalized \(file.pathExtension) TIFF metadata missing; properties=\(properties)")
        }
        try requireRecovery(
          tiff[kCGImagePropertyTIFFMake as String] == nil,
          "placeholder manufacturer does not create an Exif Make tag")
        try requireRecovery(
          tiff[kCGImagePropertyTIFFModel as String] as? String == "Fixture Camera",
          "reported model is unchanged")
      }
    }
  }

  await test("enabledAVIFAddsVerifiedMapAndPreservesPrimarySamples") {
    try await withDisparityQueue { queue, _, probe in
      let capture = disparityAVIF(true)
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .failedAddingToPhotos)
      let file = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.avif")
      let bytes = try [UInt8](Data(contentsOf: file))
      let primary = try LosslessAVIF.decode(encoded: bytes)
      guard case .planes(let snapshot) = capture.payload else {
        throw DisparityQueueAssertion.failed("Missing synthetic native planes")
      }
      try requireRecovery(
        primary.planes == snapshot.contiguous, "final primary native samples exact")
      let stored = try AVIFDisparity.extract(from: bytes)
      try requireRecovery(stored.width == 2 && stored.height == 2, "requested map geometry stored")
      try requireRecovery(stored.samples == [0, 64, 128, 255], "quantized map decodes exactly")
      let primaryMetadata = try disparityPrimaryMetadata(bytes)
      let primaryXMP = String(decoding: primaryMetadata.xmp, as: UTF8.self)
      try requireRecovery(primaryXMP.contains("mwg-rs:Regions"), "primary has a focus region")
      try requireRecovery(
        primaryXMP.contains("http://www.metadataworkinggroup.com/schemas/regions/"),
        "primary uses the MWG regions namespace")
      try requireRecovery(
        stored.xmp.contains("depthBlurEffect:SimulatedAperture=\"2.8\""),
        "depth has the application aperture default")
      let syntheticMap = try RelativeDisparityMap(
        width: 2, height: 2, values: [0, 0.25, 0.5, 1])
      try requireRecovery(
        stored.xmp.contains(syntheticMap.modelIdentifier), "actual estimator identity recorded")
      try requireRecovery(
        !stored.xmp.contains("DepthAnythingV2Small"), "synthetic map never claims a bundled model")
      try requireRecovery(
        entry.encoderSettings?.contains("fdis/L008") == true,
        "journal reports stored representation")
      try requireRecovery(
        entry.encoderSettings?.contains("estimated relative disparity") == true,
        "journal labels disparity as an estimate")
      let estimatorInputs = await probe.estimatorInputs
      try requireRecovery(estimatorInputs.count == 1, "one estimator invocation")
      try requireRecovery(
        try LosslessAVIF.decode(encoded: estimatorInputs[0]) == primary,
        "estimator receives the same decoded primary image")
      try requireRecovery(await probe.importedBytes == [bytes], "importer receives finalized AVIF")
      try requireRecovery(entry.fileHashSHA256 != nil, "finalized output hash recorded")
    }
  }

  await test("sourceMetadataSurvivesAddingRenderDefaults") {
    try await withDisparityQueue { queue, _, _ in
      var capture = disparityAVIF(true)
      let exif = ExifBuilder.build(
        make: "Synthetic source", model: "Source model", software: "Source software",
        captureISO: "2026-01-02T03:04:05Z")
      let sourceXMP = Array(
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:unknown="urn:pixelbooth:synthetic:unknown"
        xmlns:pbx="https://pixelbooth.app/ns/2026/09/capture/"
        unknown:PrivateValue="source-unknown-value" pbx:EncoderSettings="source-wins">
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """.utf8)
      capture.metadata.embeddedSourceExif = exif
      capture.metadata.embeddedSourceXMP = sourceXMP
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .failedAddingToPhotos)
      let file = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.avif")
      let bytes = try [UInt8](Data(contentsOf: file))
      let metadata = try disparityPrimaryMetadata(bytes)
      try requireRecovery(metadata.exif == exif, "source Exif remains byte-exact")
      let xmp = String(decoding: metadata.xmp, as: UTF8.self)
      try requireRecovery(xmp.contains("source-unknown-value"), "unknown source XMP preserved")
      try requireRecovery(xmp.contains("source-wins"), "source XMP conflict wins")
      try requireRecovery(xmp.contains("mwg-rs:Regions"), "application focus added to source XMP")
      try requireRecovery(
        try LosslessAVIF.decode(encoded: bytes).planes
          == syntheticNV12Snapshot(width: 4, height: 2).contiguous,
        "metadata merging preserves native primary samples")
    }
  }

  await test("legacyAndDisabledAVIFAndRequestedJPEGSkipEstimation") {
    try await withDisparityQueue { queue, _, probe in
      let captures = [disparityAVIF(nil), disparityAVIF(false), disparityJPEG(true)]
      for capture in captures {
        let serialized = try JSONEncoder().encode(capture)
        let restored = try JSONDecoder().decode(CapturedCapture.self, from: serialized)
        try requireRecovery(
          restored.metadata.includeEstimatedDisparity == capture.metadata.includeEstimatedDisparity,
          "optional shutter request survives JSON")
        if capture.metadata.includeEstimatedDisparity == nil {
          let document = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]
          let metadata = document["metadata"] as! [String: Any]
          try requireRecovery(metadata["includeEstimatedDisparity"] == nil, "legacy key is absent")
        }
        try await queue.enqueue(restored)
        let entry = try await waitForDisparityStage(queue, restored, .failedAddingToPhotos)
        try requireRecovery(
          entry.encoderSettings?.contains("disparity") != true, "no disparity settings advertised")
        if case .jpegBytes(let original) = capture.payload {
          let output = URL(fileURLWithPath: entry.stagingPath).appendingPathComponent("capture.jpg")
          let saved = try [UInt8](Data(contentsOf: output))
          let before = try JPEGParser.parse(original)
          let after = try JPEGParser.parse(saved)
          try requireRecovery(
            before.scanAndEOI == after.scanAndEOI, "JPEG scan payload unchanged")
          try requireRecovery(entry.codec == "jpeg-passthrough", "JPEG output remains passthrough")
        }
      }
      try requireRecovery(
        await probe.estimatorInputs.isEmpty, "disabled paths never invoke estimator")
      try requireRecovery(
        await probe.importedFiles.count == 3, "all ordinary outputs reach importer")
    }
  }

  await test("waitingShutterRequestSurvivesTerminationAndRelaunch") {
    let probe = DisparityQueueProbe(holdFirstImport: true)
    try await withDisparityQueue(probe: probe) { queue, root, probe in
      let first = disparityJPEG(nil)
      let waiting = disparityAVIF(true)
      try await queue.enqueue(first)
      _ = try await waitForDisparityStage(queue, first, .addingToPhotos)
      try await queue.enqueue(waiting)
      let queued = try await waitForDisparityStage(queue, waiting, .capturedLocally)
      let source = URL(fileURLWithPath: queued.stagingPath).appendingPathComponent("capture.json")
      let staged = try JSONDecoder().decode(CapturedCapture.self, from: Data(contentsOf: source))
      try requireRecovery(
        staged.metadata.includeEstimatedDisparity == true, "shutter request durable")
      try requireRecovery(await probe.estimatorInputs.isEmpty, "waiting source not yet encoded")
      await stopDisparityQueue(queue, probe)

      let relaunchedProbe = DisparityQueueProbe()
      let relaunched = SaveQueueActor(
        stagingRoot: root.appendingPathComponent("staging"),
        importer: { file, _ in await relaunchedProbe.importFile(file) },
        disparityEstimator: { primary in try await relaunchedProbe.estimate(primary) })
      do {
        try await relaunched.reconcileOnLaunch()
        let recovered = try await waitForDisparityStage(relaunched, waiting, .failedAddingToPhotos)
        let file = URL(fileURLWithPath: recovered.stagingPath).appendingPathComponent(
          "capture.avif")
        _ = try AVIFDisparity.extract(from: [UInt8](Data(contentsOf: file)))
        try requireRecovery(
          await relaunchedProbe.estimatorInputs.count == 1, "recovery honors persisted request")
        try requireRecovery(
          await relaunchedProbe.importedFiles.count == 1,
          "only waiting capture resumes automatically")
      } catch {
        await stopDisparityQueue(relaunched, relaunchedProbe)
        throw error
      }
      await stopDisparityQueue(relaunched, relaunchedProbe)
    }
  }

  await test("estimatorFailureRetainsSourceWithoutImportOrPartialFinalFile") {
    try await withDisparityQueue(probe: DisparityQueueProbe(failEstimation: true)) {
      queue, _, probe in
      let capture = disparityAVIF(true)
      try await queue.enqueue(capture)
      let entry = try await waitForDisparityStage(queue, capture, .failedEncoding)
      let directory = URL(fileURLWithPath: entry.stagingPath)
      let staged = try JSONDecoder().decode(
        CapturedCapture.self,
        from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
      try requireRecovery(staged.metadata == capture.metadata, "failed request metadata retained")
      if case .planes(let before) = capture.payload, case .planes(let after) = staged.payload {
        try requireRecovery(before == after, "immutable native source retained")
      } else {
        throw DisparityQueueAssertion.failed("Retained source payload changed kind")
      }
      try requireRecovery(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("capture.avif").path),
        "failed request leaves no finalized primary-only AVIF")
      try requireRecovery(
        entry.codecFileName == nil && entry.fileHashSHA256 == nil,
        "failed request is never marked finalized")
      try requireRecovery(
        entry.lastError?.contains("Synthetic disparity estimator failure") == true,
        "estimator failure remains actionable")
      try requireRecovery(
        await probe.importedFiles.isEmpty, "failed request never reaches importer")
    }
  }

  await test("mapReservationRefusesBeforeStagingWhenOnlyOrdinaryAVIFFits") {
    let capacity = UInt64(11 * 1024 * 1024)
    try await withDisparityQueue(maximumStagedBytes: capacity) { queue, root, probe in
      let requested = disparityAVIF(true)
      do {
        try await queue.enqueue(requested)
        throw DisparityQueueAssertion.failed("Disparity output allowance was not reserved")
      } catch SaveQueueActor.QueueError.capacityExceeded {}
      try requireRecovery(
        !FileManager.default.fileExists(
          atPath: root.appendingPathComponent("staging/\(requested.uuid.uuidString)").path),
        "capacity refusal leaves no source directory")
      try requireRecovery(
        try await queue.entries().isEmpty, "capacity refusal creates no journal row")
      let ordinary = disparityAVIF(false)
      try await queue.enqueue(ordinary)
      let entry = try await waitForDisparityStage(queue, ordinary, .failedAddingToPhotos)
      try requireRecovery(
        entry.stagingReservationBytes.map { $0 <= capacity } == true,
        "same native image fits without estimated-map allowance")
      try requireRecovery(
        await probe.estimatorInputs.isEmpty, "refused capture does not start inference")
    }
  }

  await test("estimationSuspensionKeepsFollowingCaptureDurableAndSerialized") {
    let probe = DisparityQueueProbe(holdFirstEstimate: true)
    try await withDisparityQueue(probe: probe) { queue, _, probe in
      let captures = [disparityAVIF(true), disparityAVIF(true)]
      try await queue.enqueue(captures[0])
      for _ in 0..<200 {
        if await probe.estimatorInputs.count == 1 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try requireRecovery(await probe.estimatorInputs.count == 1, "first estimator starts")
      try await queue.enqueue(captures[1])
      let waiting = try await waitForDisparityStage(queue, captures[1], .capturedLocally)
      try requireRecovery(waiting.codecFileName == nil, "following capture stays durably unencoded")
      try requireRecovery(await probe.estimatorInputs.count == 1, "no overlapping inference")
      await probe.release()
      for capture in captures {
        _ = try await waitForDisparityStage(queue, capture, .failedAddingToPhotos)
      }
      try requireRecovery(await probe.maximumActiveEstimates == 1, "one active estimation job")
      try requireRecovery(
        await probe.importedFiles.map { $0.deletingLastPathComponent().lastPathComponent }
          == captures.map { $0.uuid.uuidString }, "estimated captures preserve FIFO import order")
    }
  }
}
