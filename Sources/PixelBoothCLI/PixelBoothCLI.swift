import AVFoundation
import Darwin
import Foundation
import PixelBoothCommand
import PixelBoothLibrary
import os

@main
struct PixelBoothCLI {
  static func main() async {
    // Failed pipes must become recoverable output errors rather than terminate
    // the process before its retained source and journal can be reported.
    signal(SIGPIPE, SIG_IGN)
    let options: CaptureCommandOptions
    do {
      options = try CaptureCommandOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
      diagnostic(error.localizedDescription)
      diagnostic("Use --help for usage.")
      exit(2)
    }
    do {
      switch options.action {
      case .help:
        try write(CaptureCommandOptions.help + "\n", to: .standardOutput)
        exit(0)
      case .version:
        let version =
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        try write("pixelbooth \(version ?? "development")\n", to: .standardOutput)
        exit(0)
      case .capture: break
      }
    } catch {
      diagnostic(error.localizedDescription)
      exit(1)
    }

    let camera = SinglePhotoCapture()
    let operation = Task { try await run(options, camera: camera) }
    let interrupts = CaptureInterrupts {
      operation.cancel()
      Task { await camera.cancel() }
    }
    let status: Int32
    do {
      try await operation.value
      status = 0
    } catch {
      diagnostic(error.localizedDescription)
      if error is CameraPermissionError {
        status = 3
      } else if error is CaptureCommandError {
        status = 2
      } else {
        status = 1
      }
    }
    let interruptedStatus = interrupts.exitStatus
    interrupts.cancel()
    exit(interruptedStatus ?? status)
  }

  private static func run(_ options: CaptureCommandOptions, camera: SinglePhotoCapture) async throws
  {
    let recoveryURL = options.recoveryURL()
    let resources = try depthResources(
      enabled: options.includeEstimatedDisparity || recoveryURL != nil,
      required: options.includeEstimatedDisparity)
    let exporter = StandaloneCaptureExporter(
      stagingRoot: recoveryURL?.deletingLastPathComponent(),
      configurationURL: resources?.configuration, modelURL: resources?.model)
    var prepared: PreparedCaptureExport?
    var savedURL: URL?
    do {
      let image: PreparedCaptureExport
      if let recoveryURL {
        image = try await exporter.resume(recoveryDirectory: recoveryURL)
      } else {
        try await authorizeCamera()
        try Task.checkCancellation()
        let capture = try await camera.capture(
          timeoutSeconds: options.timeoutSeconds,
          includeEstimatedDisparity: options.includeEstimatedDisparity)
        try Task.checkCancellation()
        image = try await exporter.prepare(capture)
      }
      prepared = image
      try Task.checkCancellation()
      if let destination = try options.destination(
        fileExtension: image.fileExtension, captureUUID: image.captureUUID)
      {
        let saved = try await exporter.publish(image, to: destination)
        savedURL = saved
        try write(saved.path + "\n", to: .standardOutput)
      } else {
        try Base64FileOutput.write(
          file: image.finalizedURL, to: .standardOutput, expectedSHA256: image.fileHashSHA256)
        try await exporter.completeStandardOutput(image)
      }
      if image.hasMetadataReport {
        diagnostic("Metadata diagnostic evidence retained at \(image.recoveryDirectory.path)")
      }
    } catch {
      await camera.cancel()
      if let prepared {
        try? await exporter.recordFailure(prepared, message: error.localizedDescription)
      }
      if let recovery = await exporter.recoveryDirectory ?? recoveryURL,
        FileManager.default.fileExists(atPath: recovery.path)
      {
        diagnostic("Recovery directory: \(recovery.path)")
      }
      if let savedURL { diagnostic("Saved photograph remains at \(savedURL.path)") }
      throw error
    }
  }

  private static func authorizeCamera() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return
    case .notDetermined:
      let request = CameraAuthorizationRequest()
      let granted = try await withTaskCancellationHandler {
        try await request.wait()
      } onCancel: {
        Task { await request.cancel() }
      }
      guard granted else {
        throw CameraPermissionError()
      }
    case .denied, .restricted: throw CameraPermissionError()
    @unknown default: throw CameraPermissionError()
    }
  }

  private struct DepthResources {
    var configuration: URL
    var model: URL
  }

  private static func depthResources(enabled: Bool, required: Bool) throws -> DepthResources? {
    guard enabled else { return nil }
    let environment = ProcessInfo.processInfo.environment
    let configurationPath = environment["PIXELBOOTH_DEPTH_CONFIGURATION"]
    let modelPath = environment["PIXELBOOTH_DEPTH_MODEL"]
    guard (configurationPath == nil) == (modelPath == nil) else {
      throw CaptureCommandError(
        "set both PIXELBOOTH_DEPTH_CONFIGURATION and PIXELBOOTH_DEPTH_MODEL")
    }
    let executable =
      Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
      .appendingPathComponent("pixelbooth-resources", isDirectory: true)
    let resources = DepthResources(
      configuration: configurationPath.map { URL(fileURLWithPath: $0) }
        ?? directory.appendingPathComponent("DepthModel.json"),
      model: modelPath.map { URL(fileURLWithPath: $0) }
        ?? directory.appendingPathComponent("PixelBoothDepth.mlmodelc", isDirectory: true))
    guard FileManager.default.fileExists(atPath: resources.configuration.path),
      FileManager.default.fileExists(atPath: resources.model.path)
    else {
      if !required, configurationPath == nil { return nil }
      throw CaptureCommandError(
        "estimated disparity resources are missing; run scripts/build_cli.sh --with-disparity")
    }
    return resources
  }

  private static func write(_ value: String, to output: FileHandle) throws {
    try CommandOutput.write(Data(value.utf8), to: output)
  }

  private static func diagnostic(_ message: String) {
    // Recovery locations must still be reported from a cancelled task. Keep
    // diagnostics best-effort and nonblocking if their reader has also stalled.
    let descriptor = STDERR_FILENO
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }
    Data("pixelbooth: \(message)\n".utf8).withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written == -1, errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
  }
}

/// Authorization UI is outside the acquisition timeout, but Ctrl-C must still
/// release the command while the system is waiting for the user's response.
private actor CameraAuthorizationRequest {
  private var continuation: CheckedContinuation<Bool, any Error>?
  private var cancelled = false

  func wait() async throws -> Bool {
    try Task.checkCancellation()
    guard !cancelled else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      AVCaptureDevice.requestAccess(for: .video) { granted in
        Task { await self.finish(.success(granted)) }
      }
    }
  }

  func cancel() {
    cancelled = true
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: Result<Bool, any Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

private struct CameraPermissionError: Error, LocalizedError {
  var errorDescription: String? {
    "Camera access is unavailable. Allow camera access for this command or its terminal in System Settings > Privacy & Security > Camera, then retry interactively."
  }
}

/// Dispatch owns signal delivery; only the small exit-status value crosses
/// queues under a lock. No Swift work runs in a POSIX signal handler.
private struct CaptureInterrupts {
  private let sources: [DispatchSourceSignal]
  private let receivedSignal = OSAllocatedUnfairLock(initialState: Int32(0))

  init(onInterrupt: @escaping @Sendable () -> Void) {
    let receivedSignal = self.receivedSignal
    sources = [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: number, queue: .global(qos: .userInitiated))
      source.setEventHandler {
        receivedSignal.withLock { value in
          if value == 0 { value = number }
        }
        onInterrupt()
      }
      source.resume()
      return source
    }
  }

  var exitStatus: Int32? {
    receivedSignal.withLock { $0 == 0 ? nil : 128 + $0 }
  }

  func cancel() {
    for source in sources { source.cancel() }
  }
}
