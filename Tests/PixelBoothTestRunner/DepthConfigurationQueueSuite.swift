import Foundation
import PixelBoothAVIF
import PixelBoothDepth
import PixelBoothLibrary

private enum DepthConfigurationQueueAssertion: Error { case failed(String) }

private actor ConfiguredDepthQueueProbe {
  private var maps: [RelativeDisparityMap]
  private(set) var estimatorCalls = 0
  private(set) var importedFiles: [URL] = []

  init(maps: [RelativeDisparityMap]) { self.maps = maps }

  func estimate(_ primary: [UInt8]) throws -> RelativeDisparityMap {
    _ = try LosslessAVIF.decode(encoded: primary)
    guard !maps.isEmpty else {
      throw DepthConfigurationQueueAssertion.failed("Unexpected additional estimation")
    }
    estimatorCalls += 1
    return maps.removeFirst()
  }

  func importFile(_ file: URL) -> SaveQueueActor.ImportResult {
    importedFiles.append(file)
    return .failed("Synthetic import failure; configured output retained")
  }
}

private func configuredQueueCapture() -> CapturedCapture {
  var capture = CapturedCapture.makeTestCapture(
    fourCC: 0x4e56_3132, width: 4, height: 2,
    payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
  capture.color = CapturedCapture.ColorDescriptor(
    yuvRange: .full, primaries: nil, transfer: nil, matrix: nil,
    chromaLocation: nil, iccProfile: nil)
  capture.metadata.includeEstimatedDisparity = true
  return capture
}

private func syntheticDepthConfiguration(
  identifier: String, sourceRevision: String, modelSHA256: String, weightsSHA256: String,
  inputWidth: Int, inputHeight: Int,
  outputWidth: Int, outputHeight: Int,
  representation: DepthModelConfiguration.OutputRepresentation,
  shape: [Int]? = nil, normalized: Bool
) throws -> DepthModelConfiguration {
  try DepthModelConfiguration(
    modelIdentifier: identifier, sourceRevision: sourceRevision,
    sourceModelSHA256: modelSHA256, sourceWeightsSHA256: weightsSHA256,
    licenseIdentifier: "synthetic-test-license",
    inputFeatureName: "fixture-image", inputWidth: inputWidth, inputHeight: inputHeight,
    outputFeatureName: "fixture-depth", outputWidth: outputWidth, outputHeight: outputHeight,
    outputRepresentation: representation, outputShape: shape,
    outputNormalizedByMaximum: normalized)
}

private func waitForConfiguredQueueOutput(
  _ queue: SaveQueueActor, capture: CapturedCapture
) async throws -> SaveQueueActor.JournalEntry {
  for _ in 0..<200 {
    if let entry = try await queue.entries().first(where: { $0.uuid == capture.uuid }),
      entry.stage == .failedAddingToPhotos
    {
      return entry
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  throw DepthConfigurationQueueAssertion.failed("Configured output did not reach importer")
}

func runDepthConfigurationQueueSuite() async {
  suite("DepthConfigurationQueue")

  await test("eachOutputUsesActualModelGeometryAndProvenance") {
    let firstConfiguration = try syntheticDepthConfiguration(
      identifier: "synthetic-queue/SmallF32@test-only",
      sourceRevision: String(repeating: "a", count: 40),
      modelSHA256: String(repeating: "0", count: 64),
      weightsSHA256: String(repeating: "1", count: 64), inputWidth: 12, inputHeight: 8,
      outputWidth: 5, outputHeight: 3, representation: .imageFloat32, normalized: true)
    let secondConfiguration = try syntheticDepthConfiguration(
      identifier: "synthetic-queue/PersonalLarge@test-only",
      sourceRevision: String(repeating: "b", count: 40),
      modelSHA256: String(repeating: "2", count: 64),
      weightsSHA256: String(repeating: "3", count: 64), inputWidth: 10, inputHeight: 10,
      outputWidth: 3, outputHeight: 5, representation: .multiArrayFloat16,
      shape: [1, 5, 3], normalized: false)
    let maps = [
      try RelativeDisparityMap(
        width: 5, height: 3, values: (0..<15).map { Float($0) / 14 },
        configuration: firstConfiguration),
      try RelativeDisparityMap(
        width: 3, height: 5, values: (0..<15).map { Float($0 + 2) },
        configuration: secondConfiguration),
    ]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pb-depth-configured-queue-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ConfiguredDepthQueueProbe(maps: maps)
    let queue = SaveQueueActor(
      stagingRoot: root.appendingPathComponent("staging"),
      importer: { file, _ in await probe.importFile(file) },
      disparityEstimator: { primary in try await probe.estimate(primary) })
    do {
      let configurations = [firstConfiguration, secondConfiguration]
      for (index, configuration) in configurations.enumerated() {
        let capture = configuredQueueCapture()
        try await queue.enqueue(capture)
        let entry = try await waitForConfiguredQueueOutput(queue, capture: capture)
        let directory = URL(fileURLWithPath: entry.stagingPath)
        let bytes = try [UInt8](Data(contentsOf: directory.appendingPathComponent("capture.avif")))
        let stored = try AVIFDisparity.extract(from: bytes)
        try requireRecovery(
          stored.width == configuration.outputWidth && stored.height == configuration.outputHeight,
          "actual model output dimensions are used independently of input dimensions")
        try requireRecovery(
          stored.xmp.contains(configuration.modelIdentifier), "actual model identity stored")
        let sourceTokens = [
          "sourceRevision=\(configuration.sourceRevision)",
          "sourceModelSHA256=\(configuration.sourceModelSHA256)",
          "sourceWeightsSHA256=\(configuration.sourceWeightsSHA256)",
        ]
        for token in sourceTokens {
          try requireRecovery(
            stored.xmp.contains(token), "exact source provenance stored: \(token)")
          try requireRecovery(
            entry.encoderSettings?.contains(token) == true,
            "journal retains source provenance: \(token)")
        }
        let otherConfiguration = configurations[1 - index]
        try requireRecovery(
          !stored.xmp.contains(otherConfiguration.modelIdentifier)
            && !stored.xmp.contains(otherConfiguration.sourceRevision)
            && !stored.xmp.contains(otherConfiguration.sourceModelSHA256)
            && !stored.xmp.contains(otherConfiguration.sourceWeightsSHA256),
          "previous or following job identity cannot leak into this output")
        try requireRecovery(
          stored.xmp.contains(configuration.preprocessingDescription),
          "actual input dimensions and preprocessing stored")
        try requireRecovery(
          stored.xmp.contains(configuration.outputRepresentation.rawValue)
            && stored.xmp.contains(configuration.licenseIdentifier)
            && stored.xmp.contains(
              configuration.outputNormalizedByMaximum
                ? "normalized by the model&apos;s per-image maximum" : "unnormalized model values"),
          "actual representation, normalization and license stored")
        try requireRecovery(
          !stored.xmp.contains("518x392"), "no fixed Small input geometry claimed")
        try requireRecovery(
          entry.encoderSettings?.contains(configuration.modelIdentifier) == true,
          "journal inspector receives the actual model identity")
        try requireRecovery(
          entry.encoderSettings?.contains(
            "\(configuration.outputWidth)×\(configuration.outputHeight)")
            == true, "journal reports actual output geometry")
        let staged = try JSONDecoder().decode(
          CapturedCapture.self,
          from: Data(contentsOf: directory.appendingPathComponent("capture.json")))
        try requireRecovery(staged.metadata == capture.metadata, "shutter metadata stays immutable")
        guard case .planes(let source) = capture.payload else {
          throw DepthConfigurationQueueAssertion.failed("Missing native fixture planes")
        }
        try requireRecovery(
          try LosslessAVIF.decode(encoded: bytes).planes == source.contiguous,
          "configured inference output cannot change archival native channels")
        let minimum = Double(maps[index].values.min()!)
        let span = Double(maps[index].values.max()!) - minimum
        let expected = maps[index].values.map { value in
          UInt8(((Double(value) - minimum) / span * 255).rounded())
        }
        try requireRecovery(stored.samples == expected, "all configured prepared samples exact")
      }
      try requireRecovery(await probe.estimatorCalls == 2, "one actual map per requested capture")
      try requireRecovery(await probe.importedFiles.count == 2, "both finalized outputs imported")
    } catch {
      _ = await queue.beginTermination()
      await queue.waitForTerminationWorkToFinish()
      throw error
    }
    _ = await queue.beginTermination()
    await queue.waitForTerminationWorkToFinish()
  }
}
