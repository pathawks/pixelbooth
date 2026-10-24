import CryptoKit
import Foundation
import PixelBoothCommand
import PixelBoothLibrary

func runCaptureCommandSuite() async {
  suite("CaptureCommand")

  await test("defaultsAndConfigurableIntegerTimeout") {
    let defaults = try CaptureCommandOptions(arguments: [])
    check(defaults.timeoutSeconds == 10 && defaults.output == .pictures, "defaults")
    check(!defaults.includeEstimatedDisparity, "disparity requires an explicit request")
    let configured = try CaptureCommandOptions(arguments: ["--timeout", "27", "-o", "-"])
    check(
      configured.timeoutSeconds == 27 && configured.output == .standardOutput, "integer timeout")
    let inline = try CaptureCommandOptions(arguments: ["--timeout=1", "--output-dir=./photos"])
    check(inline.timeoutSeconds == 1 && inline.output == .directory("./photos"), "inline values")
    check(
      CaptureCommandOptions.maximumTimeoutSeconds == SinglePhotoCapture.maximumTimeoutSeconds,
      "CLI and acquisition accept the same representable timeout range")
  }

  await test("rejectsInvalidTimeoutAndConflictingDestinations") {
    for value in ["0", "-1", "1.5", "1e1", "+3", "", " 3", "１２", "999999999999999999999"] {
      expectThrows(
        { try CaptureCommandOptions(arguments: ["--timeout", value]) },
        "reject malformed or unrepresentable timeout \(value)")
    }
    for arguments in [
      ["--timeout"], ["--output"], ["--output", ""], ["--output=bad.png"],
      ["--output=a.avif", "--output-dir=photos"], ["--timeout=1", "--timeout=2"],
      ["--unknown"], ["--output", "bad\0name"], ["--output", "directory/"],
    ] {
      expectThrows({ try CaptureCommandOptions(arguments: arguments) }, "reject invalid arguments")
    }
  }

  await test("outputNamesFollowActualCodecWithoutTranscoding") {
    let identifier = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
    let working = URL(fileURLWithPath: "/tmp/test-working", isDirectory: true)
    let defaults = try CaptureCommandOptions(arguments: [])
    let destination = try defaults.destination(
      fileExtension: "jpg", captureUUID: identifier, homeDirectory: home, workingDirectory: working)
    check(
      destination?.path
        == "/tmp/test-home/Pictures/capture-01234567-89ab-cdef-0123-456789abcdef.jpg",
      "default filename identifies immutable capture and actual extension")
    let relative = try CaptureCommandOptions(arguments: ["--output", "photo.JPEG"])
    check(
      try relative.destination(
        fileExtension: "jpg", captureUUID: identifier, workingDirectory: working)?
        .path == "/tmp/test-working/photo.JPEG", "relative path and JPEG alias")
    expectThrows(
      { try relative.destination(fileExtension: "avif", captureUUID: identifier) },
      "filename cannot force JPEG recompression of an AVIF-mode capture")
    let exact = try CaptureCommandOptions(arguments: ["-o", "extensionless"])
    check(
      try exact.destination(
        fileExtension: "avif", captureUUID: identifier, workingDirectory: working)?
        .lastPathComponent == "extensionless", "explicit filename is verbatim")
    let stdout = try CaptureCommandOptions(arguments: ["--output=-"])
    check(try stdout.destination(fileExtension: "avif", captureUUID: identifier) == nil, "stdout")
  }

  await test("streamedBase64MatchesWholeFileAcrossChunkBoundaries") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for count in [0, 1, 2, 3, 49_151, 49_152, 49_153, 98_305] {
      let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      let input = root.appendingPathComponent("input")
      let output = root.appendingPathComponent("output")
      try bytes.write(to: input)
      check(FileManager.default.createFile(atPath: output.path, contents: nil), "create output")
      let handle = try FileHandle(forWritingTo: output)
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      try Base64FileOutput.write(file: input, to: handle, expectedSHA256: hash)
      try handle.close()
      let actual = try Data(contentsOf: output)
      check(
        actual == Data((bytes.base64EncodedString() + "\n").utf8),
        "exact unwrapped base64 including padding at length \(count)")
    }
  }

  await test("stalledOutputPipeCanBeCancelled") {
    let pipe = Pipe()
    let writer = Task.detached {
      defer { try? pipe.fileHandleForWriting.close() }
      try CommandOutput.write(Data(repeating: 37, count: 1_048_576), to: pipe.fileHandleForWriting)
    }
    // A delayed drain bounds this regression test even if writes stop observing
    // cancellation: such a regression fails the timing check instead of hanging.
    let drainer = Task.detached {
      try await Task.sleep(nanoseconds: 500_000_000)
      while let bytes = try pipe.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {}
      try pipe.fileHandleForReading.close()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let start = ContinuousClock.now
    writer.cancel()
    do {
      try await writer.value
      recordFailure("stalled output unexpectedly completed")
    } catch is CancellationError {
      check(start.duration(to: .now) < .milliseconds(300), "interruption does not await a reader")
    }
    try await drainer.value
  }

  await test("stdoutIntegrityFailureDoesNotEmitSuccessNewline") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input")
    let output = root.appendingPathComponent("output")
    try Data([1, 2, 3, 4]).write(to: input)
    check(FileManager.default.createFile(atPath: output.path, contents: nil), "create output")
    let handle = try FileHandle(forWritingTo: output)
    expectThrows(
      {
        try Base64FileOutput.write(
          file: input, to: handle, expectedSHA256: String(repeating: "0", count: 64))
      },
      "a changed finalized file cannot count as successful stdout delivery")
    try handle.close()
    check(try Data(contentsOf: output).last != 10, "failed stdout has no completion newline")
  }
}
