import Foundation
import PixelBoothCore
import PixelBoothLibrary

private struct CLIProcessResult {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

private func runCLI(_ arguments: [String]) throws -> CLIProcessResult {
  guard let executable = ProcessInfo.processInfo.environment["PIXELBOOTH_CLI_EXECUTABLE"] else {
    try skipTest("set PIXELBOOTH_CLI_EXECUTABLE to the built CLI; these tests never open a camera")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  try process.run()
  DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    if process.isRunning { process.terminate() }
  }
  let stdout = try output.fileHandleForReading.readToEnd() ?? Data()
  let stderr = try errors.fileHandleForReading.readToEnd() ?? Data()
  process.waitUntilExit()
  return CLIProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func runCLIIntegrationSuite() async {
  suite("CLIIntegration")

  await test("helpVersionAndInvalidIntegerTimeoutDoNotCapture") {
    let help = try runCLI(["--help"])
    check(help.status == 0 && help.stderr.isEmpty, "help succeeds with clean stderr")
    check(
      String(decoding: help.stdout, as: UTF8.self).contains("--timeout"), "timeout is documented")
    let version = try runCLI(["--version"])
    check(version.status == 0 && version.stderr.isEmpty, "version succeeds")
    let invalid = try runCLI(["--timeout", "1.5"])
    check(
      invalid.status == 2 && invalid.stdout.isEmpty, "invalid arguments fail before camera access")
    check(!invalid.stderr.isEmpty, "argument error is written to stderr")
  }

  await test("retainedPhotographExportsAsExactBase64WithoutCameraAccess") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let exporter = StandaloneCaptureExporter(stagingRoot: root)
    let capture = CapturedCapture.makeTestCapture(
      fourCC: PixelFormatFourCC.mjpeg, width: 16, height: 16, payload: .jpegBytes(jpegFixture()))
    let prepared = try await exporter.prepare(capture)
    let expected = try Data(contentsOf: prepared.finalizedURL)
    try await exporter.recordFailure(prepared, message: "synthetic output failure")
    let result = try runCLI(["--recover", prepared.recoveryDirectory.path, "--output", "-"])
    check(
      result.status == 0,
      "recovery stdout succeeds: \(String(decoding: result.stderr, as: UTF8.self))")
    check(
      result.stdout == Data((expected.base64EncodedString() + "\n").utf8), "stdout is exact base64")
    check(
      !FileManager.default.fileExists(atPath: prepared.recoveryDirectory.path),
      "success cleans staging")
  }

  await test("retainedPhotographPublishesExactFileAndOnlyItsAbsolutePath") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let exporter = StandaloneCaptureExporter(stagingRoot: root.appendingPathComponent("staging"))
    let capture = CapturedCapture.makeTestCapture(
      fourCC: PixelFormatFourCC.mjpeg, width: 16, height: 16, payload: .jpegBytes(jpegFixture()))
    let prepared = try await exporter.prepare(capture)
    let expected = try Data(contentsOf: prepared.finalizedURL)
    try await exporter.recordFailure(prepared, message: "synthetic output failure")
    let destination = root.appendingPathComponent("output/photograph.jpg")
    let result = try runCLI([
      "--recover", prepared.recoveryDirectory.path, "--output", destination.path,
    ])
    check(
      result.status == 0,
      "recovery file succeeds: \(String(decoding: result.stderr, as: UTF8.self))")
    check(result.stdout == Data((destination.path + "\n").utf8), "stdout contains only destination")
    check(try Data(contentsOf: destination) == expected, "published bytes match verified image")
  }

  await test("recoveryUsesSavedDisparityChoiceWithoutRepeatingFlag") {
    guard ProcessInfo.processInfo.environment["PIXELBOOTH_DEPTH_MODEL"] != nil,
      ProcessInfo.processInfo.environment["PIXELBOOTH_DEPTH_CONFIGURATION"] != nil
    else { try skipTest("requires prepared pinned-model resources") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var capture = CapturedCapture.makeTestCapture(
      fourCC: PixelFormatFourCC.nv12, width: 4, height: 2,
      payload: .planes(syntheticNV12Snapshot(width: 4, height: 2)))
    capture.color = CapturedCapture.ColorDescriptor(
      yuvRange: .full, primaries: 1, transfer: 13, matrix: 1,
      chromaLocation: nil, iccProfile: nil)
    capture.metadata.includeEstimatedDisparity = true
    let exporter = StandaloneCaptureExporter(
      stagingRoot: root,
      disparityEstimator: { _ in throw CaptureCommandIntegrationError.syntheticInferenceFailure })
    do {
      _ = try await exporter.prepare(capture)
      recordFailure("synthetic inference unexpectedly succeeded")
    } catch CaptureCommandIntegrationError.syntheticInferenceFailure {
      // Retained source requests disparity; retry must discover available
      // model resources even though --estimated-disparity is not repeated.
    }
    guard let recovery = await exporter.recoveryDirectory else {
      throw CaptureCommandIntegrationError.missingRecovery
    }
    let result = try runCLI(["--recover", recovery.path, "--output", "-"])
    check(
      result.status == 0,
      "saved disparity choice retries: \(String(decoding: result.stderr, as: UTF8.self))")
    let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    check(Data(base64Encoded: text)?.isEmpty == false, "recovered AVIF is returned as base64")
  }
}

private enum CaptureCommandIntegrationError: Error {
  case syntheticInferenceFailure
  case missingRecovery
}
